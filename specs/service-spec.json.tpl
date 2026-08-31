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
                        "label": "Routes *",
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
                                            },
                                            {
                                                "type": "Control",
                                                "label": "Header matches",
                                                "scope": "#/properties/headers"
                                            },
                                            {
                                                "type": "Control",
                                                "label": "URL rewrite",
                                                "scope": "#/properties/rewrite"
                                            },
                                            {
                                                "type": "Control",
                                                "label": "Request headers",
                                                "scope": "#/properties/requestHeaders"
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
                                "description": "Groups allowed to access this route. Leave empty to allow any authenticated request.",
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
                            "headers": {
                                "type": "array",
                                "title": "Header matches",
                                "description": "The route only matches when every header listed here matches the request.",
                                "items": {
                                    "type": "object",
                                    "required": [
                                        "name",
                                        "value"
                                    ],
                                    "properties": {
                                        "name": {
                                            "type": "string",
                                            "title": "Header",
                                            "pattern": "^[A-Za-z0-9!#$%&'*+.^_`|~-]+$"
                                        },
                                        "value": {
                                            "type": "string",
                                            "title": "Value"
                                        },
                                        "type": {
                                            "type": "string",
                                            "title": "Match type",
                                            "enum": [
                                                "Exact",
                                                "RegularExpression"
                                            ],
                                            "default": "Exact"
                                        }
                                    }
                                },
                                "editableOn": [
                                    "create",
                                    "update"
                                ]
                            },
                            "rewrite": {
                                "type": "object",
                                "title": "URL rewrite",
                                "description": "Rewrites the request before it reaches the backend. Leave empty to forward the path unchanged.",
                                "properties": {
                                    "path": {
                                        "type": "string",
                                        "title": "Replace path prefix",
                                        "pattern": "^/([a-zA-Z0-9_\\-\\./]*)?$",
                                        "description": "Replaces the matched prefix. Example: a route on /old with /new turns /old/items into /new/items"
                                    },
                                    "hostname": {
                                        "type": "string",
                                        "title": "Replace hostname"
                                    }
                                },
                                "editableOn": [
                                    "create",
                                    "update"
                                ]
                            },
                            "requestHeaders": {
                                "type": "object",
                                "title": "Request headers",
                                "description": "Headers added to or removed from the request before it reaches the backend.",
                                "properties": {
                                    "set": {
                                        "type": "array",
                                        "title": "Set",
                                        "items": {
                                            "type": "object",
                                            "required": [
                                                "name",
                                                "value"
                                            ],
                                            "properties": {
                                                "name": {
                                                    "type": "string",
                                                    "title": "Header"
                                                },
                                                "value": {
                                                    "type": "string",
                                                    "title": "Value"
                                                }
                                            }
                                        }
                                    },
                                    "remove": {
                                        "type": "array",
                                        "title": "Remove",
                                        "items": {
                                            "type": "string"
                                        }
                                    }
                                },
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
