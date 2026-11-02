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
                "routes"
            ],
            "uiSchema": {
                "type": "VerticalLayout",
                "elements": [
                    {
                        "type": "Control",
                        "label": "Routes",
                        "scope": "#/properties/routes"
                    }
                ]
            },
            "properties": {
                "routes": {
                    "type": "array",
                    "title": "Routes",
                    "description": "Paths of this application exposed on the service's domain. Add one item per path.",
                    "minItems": 1,
                    "editableOn": ["create", "update"],
                    "items": {
                        "type": "object",
                        "required": [
                            "path"
                        ],
                        "properties": {
                            "path": {
                                "type": "string",
                                "title": "Path",
                                "pattern": "^/([a-zA-Z0-9_\\-\\.:\\*{}/]*)?$",
                                "description": "Must start with /. Examples: /api/users, /items/:id, /files/*"
                            },
                            "methods": {
                                "type": "array",
                                "title": "Verbs",
                                "description": "HTTP methods exposed on this path. Defaults to ALL (any method); pick specific verbs to expose only those.",
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
                                "default": ["ALL"]
                            },
                            "scope": {
                                "type": "string",
                                "title": "Scope",
                                "description": "Slug of the scope that receives the traffic of this path. Leave empty to use the application's only active scope whose visibility matches the service (public or private) in the link's dimensions. Required when the application has more than one."
                            },
                            "groups": {
                                "type": "array",
                                "title": "Authorized Groups",
                                "description": "Groups allowed to call this path. Add each group name and press Add. Required unless authentication is disabled for this installation.",
                                "items": {
                                    "type": "string",
                                    "pattern": "^[a-zA-Z0-9_-]+$"
                                },
                                "uniqueItems": true
                            }
                        }
                    }
                },
                "endpoints": {
                    "type": "array",
                    "title": "Endpoints",
                    "description": "Domain and path of every route this link exposes.",
                    "items": {
                        "type": "string"
                    },
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
