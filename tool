import os
import json
import requests
import urllib3
from typing import Dict, Any, Tuple

# Disable SSL warnings
urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

# Configuration from environment variables
F5_GTM_URL = os.getenv("F5_GTM_URL")
F5_GTM_USERNAME = os.getenv("F5_GTM_USERNAME")
F5_GTM_PASSWORD = os.getenv("F5_GTM_PASSWORD")


def fetch_f5_declaration(gtm_url: str) -> Dict[str, Any]:
    """Fetch the current AS3 declaration from F5 GTM."""
    url = f"https://{gtm_url}/mgmt/shared/appsvcs/declare"
    try:
        response = requests.get(url, auth=(F5_GTM_USERNAME, F5_GTM_PASSWORD), verify=False)
        response.raise_for_status()
        return response.json()
    except requests.RequestException as e:
        raise Exception(f"Failed to fetch declaration from {gtm_url}: {str(e)}")


def fetch_gtm_wideips(gtm_url: str) -> Dict[str, Any]:
    """Fetch current WideIPs from the GTM."""
    url = f"https://{gtm_url}/mgmt/tm/gtm/wideip/a"
    try:
        response = requests.get(url, auth=(F5_GTM_USERNAME, F5_GTM_PASSWORD), verify=False)
        response.raise_for_status()
        return response.json()
    except requests.RequestException as e:
        print(f"Warning: Failed to fetch WideIPs: {str(e)}")
        return {}


def normalize_name(name: str) -> str:
    """Normalize pool or monitor name by replacing hyphens with underscores."""
    return name.replace("-", "_")


def fix_declaration_pool_names(declaration: Dict[str, Any], target_tenant: str = "fringe_bm_com") -> Tuple[Dict[str, Any], Dict[str, str]]:
    """Fix pool names and ensure GSLB_Domain aligns with WideIP."""
    updated_declaration = declaration.copy()
    pool_name_mapping = {}

    if "declaration" in updated_declaration:
        declaration_root = updated_declaration["declaration"]
    else:
        declaration_root = updated_declaration

    for tenant_name, tenant in declaration_root.items():
        if not isinstance(tenant, dict) or tenant.get("class") != "Tenant" or tenant_name != target_tenant:
            continue

        for app_name, app in tenant.items():
            if not isinstance(app, dict) or app.get("class") != "Application":
                continue

            pools_to_update = {}
            existing_pools = set(app.keys())
            for item_name, item in app.items():
                if isinstance(item, dict) and item.get("class") == "GSLB_Pool":
                    if "-" in item_name:
                        new_pool_name = normalize_name(item_name)
                        pool_name_mapping[item_name] = new_pool_name
                        pools_to_update[new_pool_name] = item

            for domain_item_name, domain_item in app.items():
                if isinstance(domain_item, dict) and domain_item.get("class") == "GSLB_Domain":
                    if "pools" in domain_item:
                        for pool in domain_item["pools"]:
                            if "use" in pool:
                                if pool["use"] in pool_name_mapping:
                                    pool["use"] = pool_name_mapping[pool["use"]]
                                elif pool["use"] not in existing_pools and pool["use"] not in pools_to_update:
                                    print(f"Warning: GSLB_Domain references nonexistent pool: {pool['use']} in {tenant_name}/{app_name}")

            for old_name in pool_name_mapping.keys():
                if old_name in app:
                    del app[old_name]
            app.update(pools_to_update)

    return updated_declaration, pool_name_mapping


def wrap_declaration_for_post(fixed_declaration: Dict[str, Any], original_declaration: Dict[str, Any]) -> Dict[str, Any]:
    """Wrap the fixed declaration in an AS3 envelope."""
    as3_envelope = {
        "class": "AS3",
        "action": "deploy",
        "persist": False,
        "async": True,
        "declaration": fixed_declaration.get("declaration", fixed_declaration)
    }
    if "declaration" in original_declaration:
        declaration_root = as3_envelope["declaration"]
        if "schemaVersion" in original_declaration["declaration"]:
            declaration_root["schemaVersion"] = original_declaration["declaration"]["schemaVersion"]
        declaration_root["updateMode"] = "complete"
    return as3_envelope


def patch_gtm_wideip(gtm_url: str, wideip_name: str, old_pool: str, new_pool: str) -> None:
    """Patch a WideIP to update its pool reference."""
    url = f"https://{gtm_url}/mgmt/tm/gtm/wideip/a/{wideip_name}"
    try:
        # Fetch current WideIP config
        response = requests.get(url, auth=(F5_GTM_USERNAME, F5_GTM_PASSWORD), verify=False)
        response.raise_for_status()
        wideip_config = response.json()

        # Update pool reference
        if "pools" in wideip_config:
            for pool in wideip_config["pools"]:
                if pool["name"] == old_pool:
                    pool["name"] = new_pool
                    break

        # Patch the WideIP
        response = requests.patch(
            url,
            auth=(F5_GTM_USERNAME, F5_GTM_PASSWORD),
            json=wideip_config,
            headers={"Content-Type": "application/json"},
            verify=False
        )
        response.raise_for_status()
        print(f"Successfully patched WideIP {wideip_name} to reference {new_pool}")
    except requests.RequestException as e:
        print(f"Failed to patch WideIP {wideip_name}: {str(e)}")


def post_f5_declaration(gtm_url: str, declaration: Dict[str, Any], original_declaration: Dict[str, Any], pool_mapping: Dict[str, str]) -> None:
    """Post the updated declaration and patch WideIPs if needed."""
    url = f"https://{gtm_url}/mgmt/shared/appsvcs/declare"
    payload = wrap_declaration_for_post(declaration, original_declaration)
    
    with open("f5_declaration_posted.json", "w") as f:
        json.dump(payload, f, indent=2)
    print("Saved declaration being posted to f5_declaration_posted.json")

    try:
        headers = {"Content-Type": "application/json"}
        print(f"Posting to {url} with headers: {headers}")
        response = requests.post(
            url,
            auth=(F5_GTM_USERNAME, F5_GTM_PASSWORD),
            json=payload,
            headers=headers,
            verify=False
        )
        response.raise_for_status()
        print(f"POST request to {gtm_url} returned status code: {response.status_code}")
        print("Full response from F5:")
        if response.text:
            print(json.dumps(response.json(), indent=2))
        else:
            print("  (No response body)")
        if response.json().get("code") in (0, 404):
            print("Warning: Response indicates a potential issue. Attempting WideIP patch...")
            wideips = fetch_gtm_wideips(gtm_url)
            for old_pool, new_pool in pool_mapping.items():
                for item in wideips.get("items", []):
                    wideip_name = item["name"]
                    for pool in item.get("pools", []):
                        if pool["name"] == f"/fringe_bm_com/aaa_preprod_albs_gslb_fringe_bm_com/{old_pool}":
                            patch_gtm_wideip(gtm_url, wideip_name, old_pool, new_pool)
    except requests.RequestException as e:
        raise Exception(f"Failed to post declaration to {gtm_url}: {str(e)}")


def save_json_file(data: Dict[str, Any], filename: str) -> None:
    """Save a dictionary to a JSON file."""
    with open(filename, "w") as f:
        json.dump(data, f, indent=2)
    print(f"Saved {filename}")


def main(gtm_url: str, target_tenant: str = "fringe_bm_com") -> None:
    """Main function to fetch, backup, fix, and update the F5 GTM declaration."""
    try:
        if not all([gtm_url, F5_GTM_USERNAME, F5_GTM_PASSWORD]):
            raise ValueError("Missing required environment variables")

        print(f"Fetching declaration from {gtm_url}...")
        current_declaration = fetch_f5_declaration(gtm_url)

        print("Fetching WideIPs for debugging...")
        wideips = fetch_gtm_wideips(gtm_url)
        save_json_file(wideips, "f5_wideips.json")

        backup_filename = "f5_declaration_backup.json"
        save_json_file(current_declaration, backup_filename)

        print(f"Fixing pool names in declaration for tenant {target_tenant}...")
        fixed_declaration, pool_name_mapping = fix_declaration_pool_names(current_declaration, target_tenant)

        corrected_filename = "f5_declaration_corrected.json"
        save_json_file(fixed_declaration, corrected_filename)

        if pool_name_mapping:
            print("Changes made to pool names:")
            for old_name, new_name in pool_name_mapping.items():
                print(f"  {old_name} -> {new_name}")
        else:
            print("No pool names required updates.")

        if pool_name_mapping:
            print(f"Posting corrected declaration to {gtm_url}...")
            post_f5_declaration(gtm_url, fixed_declaration, current_declaration, pool_name_mapping)
            print("Declaration submitted. Verify the F5 GTM UI or logs at /var/log/ltm.")
            print("Check f5_wideips.json for WideIP pool references.")
        else:
            print("No changes to post to F5 GTM.")

    except Exception as e:
        print(f"Error: {str(e)}")
        raise


if __name__ == "__main__":
    main(F5_GTM_URL, target_tenant="fringe_bm_com")
