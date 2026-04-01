"""
Grants the Public role permissions required for guest token embedded dashboard access.

Guest tokens (used by the Superset Embedded SDK) inherit the Public role.
Without these permissions, embedded dashboards return 403 errors.

This script is idempotent — safe to run on every startup.
"""
from superset.app import create_app

app = create_app()

PERMISSIONS = [
    # Dashboard access
    ("can_read", "Dashboard"),
    ("can_get_embedded", "Dashboard"),
    ("can_read", "EmbeddedDashboard"),
    ("can_read", "DashboardFilterStateRestApi"),
    ("can_read", "DashboardPermalinkRestApi"),
    ("can_view_query", "Dashboard"),
    ("can_view_chart_as_table", "Dashboard"),
    ("can_drill", "Dashboard"),
    # Chart access
    ("can_read", "Chart"),
    ("can_warm_up_cache", "Chart"),
    # Dataset/datasource access
    ("can_read", "Dataset"),
    ("all_datasource_access", "all_datasource_access"),
    # Explore (needed for chart data requests)
    ("can_read", "Explore"),
    ("can_read", "ExploreFormDataRestApi"),
    ("can_read", "SavedQuery"),
]

with app.app_context():
    from superset.extensions import security_manager, db

    public_role = security_manager.find_role("Public")
    if not public_role:
        print("WARNING: Public role not found, skipping guest permissions setup")
    else:
        added = 0
        for perm_name, view_name in PERMISSIONS:
            pv = security_manager.find_permission_view_menu(perm_name, view_name)
            if pv:
                if pv not in public_role.permissions:
                    security_manager.add_permission_role(public_role, pv)
                    added += 1
            else:
                print(f"  Permission not found (may not exist yet): {perm_name} on {view_name}")

        db.session.commit()
        print(f"Guest permissions: {added} new permissions added to Public role"
              f" ({len(PERMISSIONS)} total checked)")
