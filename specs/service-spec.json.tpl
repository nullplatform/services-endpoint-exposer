{
    "name": "Endpoint Exposer",
    "slug": "http-route-access-control",
    "type": "dependency",
    "visible_to": ["{{ env.Getenv `NRN` }}"],
    "dimensions": {},
    "scopes": {},
    "assignable_to": "any",
    "use_default_actions": true,
    "attributes": {
        "schema": {
            "type": "object",
            "$schema": "http://json-schema.org/draft-07/schema#",
            "required": [],
            "uiSchema": {
                "type": "VerticalLayout",
                "elements": [
                    {
                        "type": "HorizontalLayout",
                        "elements": [
                            {
                                "type": "Control",
                                "label": "Domain name *",
                                "scope": "#/properties/domain_name"
                            },
                            {
                                "type": "Control",
                                "label": "Visibility",
                                "scope": "#/properties/visibility"
                            }
                        ]
                    }
                ]
            },
            "properties": {
                "domain_name": {
                    "type": "string",
                    "title": "Domain name",
                    "pattern": "^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\\.)+[a-z]([a-z0-9-]{0,61}[a-z0-9])?$",
                    "maxLength": 253,
                    "description": "Domain the paths of this service are exposed on, e.g. api.example.com. Each linked application adds its own path. It must be served by the gateway of the selected visibility.",
                    "editableOn": ["create"]
                },
                "visibility": {
                    "type": "string",
                    "title": "Visibility",
                    "enum": ["public", "private"],
                    "default": "public",
                    "description": "public exposes the domain on the public gateway, private on the private one.",
                    "editableOn": ["create"]
                },
                "routes": {
                    "type": "array",
                    "items": {
                        "type": "object",
                        "required": [
                            "methods",
                            "path",
                            "scope"
                        ],
                        "properties": {
                            "path": {
                                "type": "string",
                                "title": "Path",
                                "pattern": "^/([a-zA-Z0-9_\\-\\.:\\*{}/]*)?$",
                                "description": "Must start with /. Examples: /, /api, /api/v1/users, /items/:id, /files/*"
                            },
                            "scope": {
                                "type": "string",
                                "title": "Scope",
                                "description": "Scope name where the rules apply.",
                                "additionalKeywords": {
                                    "enum": "[.scopes[]?.slug] | if length == 0 then [\"No scopes available for selected environment\"] else . end"
                                }
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
                                "minItems": 1
                            },
                            "groups": {
                                "type": "array",
                                "title": "Authorized Groups",
                                "description": "Groups allowed to access this route. Add each group name and press Add. Required unless authentication is disabled for this installation.",
                                "items": {
                                    "type": "string",
                                    "pattern": "^[a-zA-Z0-9_-]+$"
                                },
                                "uniqueItems": true,
                                "editableOn": [
                                    "create",
                                    "update"
                                ]
                            },
                            "summary": {
                                "type": "string",
                                "title": "Summary",
                                "editableOn": ["create", "update"],
                                "visibleOn": []
                            }
                        }
                    }
                }
            }
        },
        "values": {}
    },
    "selectors": {
        "category": "Networking",
        "imported": false,
        "provider": "Istio",
        "sub_category": "Endpoint Exposure"
    }
}
