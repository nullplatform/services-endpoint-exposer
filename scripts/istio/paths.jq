# Route path conversion shared by the HTTPRoute and the AuthorizationPolicies,
# so the request a rule routes is exactly the request its policy admits.
#
#   /items/:id, /items/{id}  -> RegularExpression /items/[^/]+   policy /items/{*}
#   /api/*/x                 -> RegularExpression /api/[^/]+/x   policy /api/{*}/x
#   /api/*                   -> PathPrefix /api                  policy /api, /api/*
#   /*                       -> PathPrefix /                     policy /*
#   /files*                  -> RegularExpression /files.*       policy /files*
#   /health                  -> Exact /health                    policy /health
#
# path_spec returns {type, value, policy: [...]} or {error} for patterns that
# can't be expressed in both (a partial "*" inside a segment combined with
# parameters, or anywhere but the end of the path).

def _regex_escape: gsub("(?<c>[.+?^$()\\[\\]{}|\\\\])"; "\\\(.c)");
def _is_param: test("^(:[^/]+|\\{[^/{}]+\\}|\\*)$");

def path_spec:
  (if startswith("/") then . else "/" + . end) as $p
  | ($p | endswith("/*")) as $prefix
  | (if $prefix then $p[:-2] else $p end) as $base
  | ($base | split("/") | .[1:]) as $segs
  | ([$segs[] | select(_is_param)] | length > 0) as $has_params
  | ([$segs[] | select(contains("*") and . != "*")] | length) as $partials
  | if $partials > 0 then
      if $partials == 1 and ($segs[-1] | endswith("*")) and ($segs[-1][:-1] | contains("*") | not)
         and ($has_params | not) and ($prefix | not) then
        {type: "RegularExpression",
         value: (($base[:-1] | _regex_escape) + ".*"),
         policy: [$base]}
      else
        {error: "unsupported wildcard in \($p): use * as a whole segment or only at the end"}
      end
    elif $has_params then
      ("/" + ([$segs[] | if _is_param then "[^/]+" else _regex_escape end] | join("/"))) as $re
      | ("/" + ([$segs[] | if _is_param then "{*}" else . end] | join("/"))) as $tpl
      | {type: "RegularExpression",
         value: ($re + (if $prefix then "(/.*)?" else "" end)),
         policy: ([$tpl] + (if $prefix then [$tpl + "/{**}"] else [] end))}
    elif $prefix then
      if $base == "" then {type: "PathPrefix", value: "/", policy: ["/*"]}
      else {type: "PathPrefix", value: $base, policy: [$base, $base + "/*"]}
      end
    else
      {type: "Exact", value: $p, policy: [$p]}
    end;
