apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: {{ .name }}
  namespace: {{ .k8s_namespace }}
  labels:
    nullplatform.com/managed-by: http-route-access-control
    nullplatform.com/service-id: "{{ .service_id }}"
{{- if .link_id }}
    nullplatform.com/link-id: "{{ .link_id }}"
{{- end }}
    app.kubernetes.io/name: {{ .service_slug }}
spec:
  parentRefs:
    - name: {{ .gateway_name }}
      namespace: {{ .gateway_namespace }}
      group: gateway.networking.k8s.io
      kind: Gateway
  hostnames:
{{ range .hostnames }}    - {{ . }}
{{ end }}
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: response-404
          port: 80
          weight: 0
