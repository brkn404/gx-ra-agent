"""Detect hypervisor / cloud / container context for guest agents."""

from __future__ import annotations

import json
import subprocess
import urllib.error
import urllib.request
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any, Dict, Literal, Optional

VirtPlatform = Literal[
    "bare_metal",
    "vmware",
    "hyperv",
    "kvm",
    "xen",
    "qemu",
    "virtualbox",
    "parallels",
    "nutanix_ahv",
    "citrix",
    "proxmox",
    "cloud_aws",
    "cloud_azure",
    "cloud_gcp",
    "cloud_oracle",
    "container",
    "unknown",
]
VirtRole = Literal["physical", "guest_vm", "container"]


@dataclass
class VirtContext:
    """Where the agent runs — used for entity registration and genome identity."""

    role: VirtRole = "physical"
    platform: VirtPlatform = "bare_metal"
    hypervisor: Optional[str] = None
    instance_id: Optional[str] = None
    cloud_region: Optional[str] = None
    product_name: Optional[str] = None
    sys_vendor: Optional[str] = None
    detect_method: str = "none"
    extra: Dict[str, Any] = field(default_factory=dict)

    def to_source_refs(self) -> Dict[str, Any]:
        refs: Dict[str, Any] = {
            "virt_role": self.role,
            "virt_platform": self.platform,
            "agent": "gxra-agent",
        }
        if self.hypervisor:
            refs["hypervisor"] = self.hypervisor
        if self.instance_id:
            refs["instance_id"] = self.instance_id
        if self.cloud_region:
            refs["cloud_region"] = self.cloud_region
        if self.product_name:
            refs["product_name"] = self.product_name
        if self.sys_vendor:
            refs["sys_vendor"] = self.sys_vendor
        refs.update({k: v for k, v in self.extra.items() if v is not None})
        return refs

    def suggested_entity_type(self) -> str:
        if self.role == "container":
            return "workload"
        if self.role == "guest_vm":
            return "virtual_machine"
        return "server"

    def identity_suffix(self) -> str:
        """Stable string mixed into genome seed (per-VM, not per-hypervisor)."""
        parts = [self.platform, self.role]
        if self.instance_id:
            parts.append(self.instance_id)
        elif self.product_name:
            parts.append(self.product_name)
        return ":".join(parts)


def _match_platform(text: str) -> Optional[VirtPlatform]:
    t = text.lower()
    rules: list[tuple[tuple[str, ...], VirtPlatform]] = [
        (("vmware",), "vmware"),
        (("microsoft corporation", "hyper-v", "virtual machine"), "hyperv"),
        (("kvm", "qemu", "bochs"), "kvm"),
        (("xen",), "xen"),
        (("virtualbox", "innotek", "vbox"), "virtualbox"),
        (("parallels",), "parallels"),
        (("nutanix",), "nutanix_ahv"),
        (("citrix",), "citrix"),
        (("proxmox",), "proxmox"),
        (("amazon", "ec2", "aws"), "cloud_aws"),
        (("google", "gce"), "cloud_gcp"),
        (("microsoft azure", "azure"), "cloud_azure"),
        (("oraclecloud", "oracle cloud"), "cloud_oracle"),
        (("docker", "container", "podman", "kubepods"), "container"),
    ]
    for needles, plat in rules:
        if any(n in t for n in needles):
            return plat
    if "virtual" in t or "vm" in t:
        return "unknown"
    return None


def _read_linux_dmi(name: str) -> str:
    p = Path(f"/sys/class/dmi/id/{name}")
    if p.is_file():
        try:
            return p.read_text(errors="replace").strip()
        except OSError:
            return ""
    return ""


def _systemd_detect_virt() -> str:
    try:
        out = subprocess.check_output(
            ["systemd-detect-virt"],
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=3,
        )
        return out.strip().lower()
    except (OSError, subprocess.SubprocessError, FileNotFoundError):
        return "none"


def _http_metadata(url: str, headers: Optional[Dict[str, str]] = None, timeout: float = 0.5) -> Optional[str]:
    try:
        req = urllib.request.Request(url, headers=headers or {})
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.read().decode("utf-8", errors="replace").strip()
    except (urllib.error.URLError, OSError, TimeoutError):
        return None


def _cloud_aws() -> Optional[VirtContext]:
    iid = _http_metadata("http://169.254.169.254/latest/meta-data/instance-id")
    if not iid:
        return None
    region = _http_metadata("http://169.254.169.254/latest/meta-data/placement/region")
    return VirtContext(
        role="guest_vm",
        platform="cloud_aws",
        hypervisor="aws_ec2",
        instance_id=iid,
        cloud_region=region,
        detect_method="ec2_metadata",
    )


def _cloud_azure() -> Optional[VirtContext]:
    url = "http://169.254.169.254/metadata/instance?api-version=2021-02-01"
    raw = _http_metadata(url, headers={"Metadata": "true"})
    if not raw:
        return None
    try:
        data = json.loads(raw)
        vm_id = data.get("compute", {}).get("vmId")
        region = data.get("compute", {}).get("location")
        if vm_id:
            return VirtContext(
                role="guest_vm",
                platform="cloud_azure",
                hypervisor="azure_vm",
                instance_id=str(vm_id),
                cloud_region=region,
                detect_method="azure_imds",
            )
    except json.JSONDecodeError:
        pass
    return None


def _cloud_gcp() -> Optional[VirtContext]:
    iid = _http_metadata(
        "http://metadata.google.internal/computeMetadata/v1/instance/id",
        headers={"Metadata-Flavor": "Google"},
    )
    if not iid:
        return None
    zone = _http_metadata(
        "http://metadata.google.internal/computeMetadata/v1/instance/zone",
        headers={"Metadata-Flavor": "Google"},
    )
    return VirtContext(
        role="guest_vm",
        platform="cloud_gcp",
        hypervisor="gce",
        instance_id=iid,
        cloud_region=zone.split("/")[-1] if zone else None,
        detect_method="gce_metadata",
    )


def detect_virt_linux() -> VirtContext:
    product = _read_linux_dmi("product_name")
    vendor = _read_linux_dmi("sys_vendor")
    uuid = _read_linux_dmi("product_uuid")
    chassis = _read_linux_dmi("chassis_type")
    combined = f"{vendor} {product}".strip()

    sd = _systemd_detect_virt()
    if sd in ("docker", "podman", "container"):
        return VirtContext(
            role="container",
            platform="container",
            hypervisor=sd,
            instance_id=uuid or None,
            product_name=product or None,
            sys_vendor=vendor or None,
            detect_method="systemd-detect-virt",
        )

    for detector in (_cloud_aws, _cloud_azure, _cloud_gcp):
        ctx = detector()
        if ctx:
            ctx.product_name = product or ctx.product_name
            ctx.sys_vendor = vendor or ctx.sys_vendor
            if uuid and not ctx.instance_id:
                ctx.instance_id = uuid
            return ctx

    plat = _match_platform(combined) or _match_platform(sd)
    if plat and plat != "bare_metal":
        return VirtContext(
            role="guest_vm",
            platform=plat,
            hypervisor=sd if sd not in ("none", "") else plat,
            instance_id=uuid or None,
            product_name=product or None,
            sys_vendor=vendor or None,
            detect_method="dmi+systemd",
            extra={"chassis_type": chassis} if chassis else {},
        )

    if sd not in ("none", "", "kvm"):
        plat2 = _match_platform(sd) or "kvm"
        return VirtContext(
            role="guest_vm",
            platform=plat2 if plat2 else "kvm",
            hypervisor=sd,
            instance_id=uuid or None,
            product_name=product,
            sys_vendor=vendor,
            detect_method="systemd-detect-virt",
        )

    return VirtContext(
        role="physical",
        platform="bare_metal",
        instance_id=uuid or None,
        product_name=product or None,
        sys_vendor=vendor or None,
        detect_method="dmi",
    )


def _wmic_field(query: str) -> str:
    try:
        out = subprocess.check_output(
            ["wmic", query],
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=10,
        )
        lines = [ln.strip() for ln in out.splitlines() if ln.strip()]
        return lines[-1] if len(lines) > 1 else ""
    except (OSError, subprocess.SubprocessError, FileNotFoundError):
        return ""


def detect_virt_windows() -> VirtContext:
    manufacturer = _wmic_field("computersystem get manufacturer")
    model = _wmic_field("computersystem get model")
    uuid = _wmic_field("csproduct get uuid")
    combined = f"{manufacturer} {model}".strip()

    plat = _match_platform(combined)
    if plat:
        return VirtContext(
            role="guest_vm" if plat != "bare_metal" else "physical",
            platform=plat,
            hypervisor=plat,
            instance_id=uuid or None,
            product_name=model or None,
            sys_vendor=manufacturer or None,
            detect_method="wmic",
        )

    return VirtContext(
        role="physical",
        platform="bare_metal",
        instance_id=uuid or None,
        product_name=model or None,
        sys_vendor=manufacturer or None,
        detect_method="wmic",
    )


def detect_virt_darwin() -> VirtContext:
    model = ""
    try:
        out = subprocess.check_output(
            ["sysctl", "-n", "hw.model"],
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=3,
        )
        model = out.strip()
    except (OSError, subprocess.SubprocessError, FileNotFoundError):
        pass

    plat = _match_platform(model)
    if plat:
        return VirtContext(
            role="guest_vm",
            platform=plat,
            hypervisor=plat,
            product_name=model,
            detect_method="sysctl",
        )

    return VirtContext(
        role="physical",
        platform="bare_metal",
        product_name=model or None,
        detect_method="sysctl",
    )


def detect_virt(os_name: Optional[str] = None) -> VirtContext:
    """Detect virtualization context for the current host."""
    import platform as platmod

    system = (os_name or platmod.system()).lower()
    if system == "linux":
        return detect_virt_linux()
    if system == "windows":
        return detect_virt_windows()
    if system in ("darwin", "macos", "mac os x"):
        return detect_virt_darwin()
    return VirtContext(role="physical", platform="unknown", detect_method="unsupported_os")


def detect_virt_from_dmi(
    *,
    product_name: str = "",
    sys_vendor: str = "",
    product_uuid: str = "",
    systemd_virt: str = "none",
) -> VirtContext:
    """Testable DMI-based detection (Linux path)."""
    sd = systemd_virt.lower()
    if sd in ("docker", "podman", "container"):
        return VirtContext(
            role="container",
            platform="container",
            hypervisor=sd,
            instance_id=product_uuid or None,
            product_name=product_name or None,
            sys_vendor=sys_vendor or None,
            detect_method="systemd_test",
        )

    combined = f"{sys_vendor} {product_name}".strip()
    plat = _match_platform(combined) or _match_platform(systemd_virt)
    if plat and plat not in ("bare_metal",):
        return VirtContext(
            role="guest_vm",
            platform=plat,
            hypervisor=systemd_virt or plat,
            instance_id=product_uuid or None,
            product_name=product_name,
            sys_vendor=sys_vendor,
            detect_method="dmi_test",
        )
    if systemd_virt not in ("none", ""):
        return VirtContext(
            role="guest_vm",
            platform=_match_platform(systemd_virt) or "kvm",
            hypervisor=systemd_virt,
            instance_id=product_uuid or None,
            detect_method="systemd_test",
        )
    return VirtContext(
        role="physical",
        platform="bare_metal",
        instance_id=product_uuid or None,
        product_name=product_name,
        sys_vendor=sys_vendor,
        detect_method="dmi_test",
    )
