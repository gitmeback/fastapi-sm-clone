import os
import json
import requests
import urllib3
from typing import Dict, Any
import re

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
        response = requests.get(
            url,
            auth=(F5_GTM_USERNAME, F5_GTM_PASSWORD),
            verify=False
        )
        response.raise_for_status()
        return response.json()
    except requests.RequestException as e:
        raise Exception(f"Failed to fetch declaration from {gtm_url}: {str(e)}")


def normalize_name(name: str) -> str:
    """Normalize pool or monitor name by replacing hyphens with underscores."""
    return name.replace("-", "_")


def fix_declaration_pool_names(declaration: Dict[str, Any]) -> Dict[str, Any]:
    """Fix pool names in the declaration by replacing hyphens with underscores."""
    updated_declaration = declaration.copy()
    pool_name_mapping = {}  # Track old-to-new pool name changes

    # Iterate through tenants and applications
    for tenant_name, tenant in updated_declaration.get("declaration", {}).items():
        if not isinstance(tenant, dict) or tenant.get("class") != "Tenant":
            continue

        for app_name, app in tenant.items():
            if not isinstance(app, dict) or app.get("class") != "Application":
                continue

            # Identify and rename pools
            pools_to_update = {}
            for item_name, item in app.items():
                if isinstance(item, dict) and item.get("class") == "GSLB_Pool":
                    if "-" in item_name:
                        new_pool_name = normalize_name(item_name)
                        pool_name_mapping[item_name] = new_pool_name
                        pools_to_update[new_pool_name] = item

            # Update pool references in GSLB_Domain
            for domain_item_name, domain_item in app.items():
                if isinstance(domain_item, dict) and domain_item.get("class") == "GSLB_Domain":
                    if "pools" in domain_item:
                        for pool in domain_item["pools"]:
                            if "use" in pool and pool["use"] in pool_name_mapping:
                                pool["use"] = pool_name_mapping[pool["use"]]

            # Replace old pool names with new ones
            for old_name in pool_name_mapping.keys():
                if old_name in app:
                    del app[old_name]
            app.update(pools_to_update)

    return updated_declaration


def save_json_file(data: Dict[str, Any], filename: str) -> None:
    """Save a dictionary to a JSON file."""
    with open(filename, 'w') as f:
        json.dump(data, f, indent=2)
    print(f"Saved {filename}")


def main(gtm_url: str) -> None:
    """Main function to fetch, backup, and fix the F5 GTM declaration."""
    try:
        # Check environment variables
        if not all([gtm_url, F5_GTM_USERNAME, F5_GTM_PASSWORD]):
            raise ValueError("Missing required environment variables: F5_GTM_URL, F5_GTM_USERNAME, F5_GTM_PASSWORD")

        # Fetch the current declaration
        print(f"Fetching declaration from {gtm_url}...")
        current_declaration = fetch_f5_declaration(gtm_url)

        # Save a backup
        backup_filename = "f5_declaration_backup.json"
        save_json_file(current_declaration, backup_filename)

        # Fix pool names
        print("Fixing pool names in declaration...")
        fixed_declaration = fix_declaration_pool_names(current_declaration)

        # Save the corrected declaration
        corrected_filename = "f5_declaration_corrected.json"
        save_json_file(fixed_declaration, corrected_filename)

        # Optional: Uncomment the following to update the F5 GTM
        # print("Posting corrected declaration to F5 GTM...")
        # url = f"https://{gtm_url}/mgmt/shared/appsvcs/declare"
        # response = requests.post(
        #     url,
        #     auth=(F5_GTM_USERNAME, F5_GTM_PASSWORD),
        #     json=fixed_declaration,
        #     verify=False
        # )
        # response.raise_for_status()
        # print("Declaration updated successfully on F5 GTM!")

    except Exception as e:
        print(f"Error: {str(e)}")
        raise


if __name__ == "__main__":
    main(F5_GTM_URL)
