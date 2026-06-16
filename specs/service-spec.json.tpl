{
    "name": "HTTP Route Access Control",
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
                        "type": "Group",
                        "label": "Routes",
                        "elements": [
                            {
                                "type": "Control",
                                "scope": "#/properties/routes",
                                "options": {
                                    "elementLabelProp": "summary",
                                    "detail": {
                                        "type": "VerticalLayout",
                                        "elements": [
                                            {
                                                "type": "Control",
                                                "label": "Verbs",
                                                "scope": "#/properties/methods"
                                            },
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
                                                "label": "Authorized Groups",
                                                "scope": "#/properties/groups"
                                            }
                                        ]
                                    },
                                    "showSortButtons": true
                                }
                            }
                        ]
                    }
                ]
            },
            "properties": {
                "routes": {
                    "type": "array",
                    "minItems": 1,
                    "items": {
                        "type": "object",
                        "required": [
                            "methods",
                            "path",
                            "scope",
                            "groups"
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
                                "type": "string",
                                "title": "Authorized Groups",
                                "pattern": "^([a-zA-Z0-9-]+(\\s*,\\s*[a-zA-Z0-9-]+)*)?$",
                                "description": "Comma-separated list of groups allowed to access this route (letters, numbers and hyphens only).",
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
        "category": "Security",
        "imported": false,
        "provider": "Istio",
        "sub_category": "Access Control"
    }
}