apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: hrac-{{ .name }}
  namespace: {{ .gateway_namespace }}
  labels:
    nullplatform.com/managed-by: http-route-access-control
    nullplatform.com/service-id: "{{ .service_id }}"
spec:
  selector:
    matchLabels:
      gateway.networking.k8s.io/gateway-name: {{ .gateway_name }}
  action: ALLOW
  rules:
    - to:
        - operation:
            hosts: ["{{ .host }}"]
            paths: ["{{ .path }}"]
            methods: ["{{ .method }}"]
      when:
        - key: "request.auth.claims[cognito:groups]"
          values:
{{ range .groups }}          - "{{ . }}"
{{ end }}
