{
    "name": "Connect",
    "slug": "connect",
    "unique": false,
    "assignable_to": "any",
    "use_default_actions": true,
    "attributes": {
        "schema": {
            "type": "object",
            "$schema": "http://json-schema.org/draft-07/schema#",
            "required": [
                "path"
            ],
            "uiSchema": {
                "type": "VerticalLayout",
                "elements": [
                    {
                        "type": "HorizontalLayout",
                        "elements": [
                            {
                                "type": "Control",
                                "label": "Path",
                                "scope": "#/properties/path"
                            },
                            {
                                "type": "Control",
                                "label": "Scope",
                                "scope": "#/properties/scope"
                            }
                        ]
                    },
                    {
                        "type": "Control",
                        "label": "Verbs",
                        "scope": "#/properties/methods"
                    },
                    {
                        "type": "Control",
                        "label": "Authorized Groups",
                        "scope": "#/properties/groups"
                    }
                ]
            },
            "properties": {
                "path": {
                    "type": "string",
                    "title": "Path",
                    "pattern": "^/([a-zA-Z0-9_\\-\\.:\\*{}/]*)?$",
                    "description": "Path exposed on the service's domain. Must start with /. Examples: /api/users, /items/:id, /files/*",
                    "editableOn": ["create", "update"]
                },
                "scope": {
                    "type": "string",
                    "title": "Scope",
                    "description": "Slug of the scope that receives the traffic of this path. Leave empty to use the application's scope whose visibility matches the service (public or private) in the link's dimensions.",
                    "editableOn": ["create", "update"]
                },
                "methods": {
                    "type": "array",
                    "title": "Verbs",
                    "items": {
                        "type": "string",
                        "enum": [
                            "ALL",
                            "GET",
                            "POST",
                            "PUT",
                            "PATCH",
                            "DELETE",
                            "HEAD",
                            "OPTIONS"
                        ]
                    },
                    "uniqueItems": true,
                    "default": ["ALL"],
                    "description": "HTTP methods exposed on this path. Defaults to ALL (any method); pick specific verbs to expose only those.",
                    "editableOn": ["create", "update"]
                },
                "groups": {
                    "type": "array",
                    "title": "Authorized Groups",
                    "description": "Groups allowed to call this path. Add each group name and press Add. Required unless authentication is disabled for this installation.",
                    "items": {
                        "type": "string",
                        "pattern": "^[a-zA-Z0-9_-]+$"
                    },
                    "uniqueItems": true,
                    "editableOn": ["create", "update"]
                },
                "endpoint": {
                    "type": "string",
                    "title": "Endpoint",
                    "description": "Domain and path this link exposes.",
                    "editableOn": [],
                    "visibleOn": ["read"]
                },
                "summary": {
                    "type": "string",
                    "title": "Summary",
                    "editableOn": [],
                    "visibleOn": []
                }
            }
        },
        "values": {}
    }
}
