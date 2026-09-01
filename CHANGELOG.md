# Changelog

## [0.3.0](https://github.com/nullplatform/services-endpoint-exposer/compare/v0.2.3...v0.3.0) (2026-09-01)


### Features

* **ci:** build+push the worker image and register its artifact on release ([5d8bb6c](https://github.com/nullplatform/services-endpoint-exposer/commit/5d8bb6c0ad4fb390040f8b3ec8292f13dc242b9f))
* **ci:** build+push the worker image and register its artifact on release ([2cb16a0](https://github.com/nullplatform/services-endpoint-exposer/commit/2cb16a0608fd1bc591a54e624606139cf1a3b8a2))

## [0.2.3](https://github.com/nullplatform/services-endpoint-exposer/compare/v0.2.2...v0.2.3) (2026-08-10)


### Bug Fixes

* **istio:** read context from NP_ACTION_CONTEXT in fetch_provider_data ([#13](https://github.com/nullplatform/services-endpoint-exposer/issues/13)) ([2657ddf](https://github.com/nullplatform/services-endpoint-exposer/commit/2657ddf3c938555e880367a1684df33b457eb6ee))

## [0.2.2](https://github.com/nullplatform/services-endpoint-exposer/compare/v0.2.1...v0.2.2) (2026-08-10)


### Bug Fixes

* **istio:** normalize legacy string .method so the HTTPRoute is valid ([ab03ac7](https://github.com/nullplatform/services-endpoint-exposer/commit/ab03ac747abd122311d4f1fe0c94962c35befb51))
* **istio:** normalize legacy string `.method` so the HTTPRoute is valid ([e7e86c6](https://github.com/nullplatform/services-endpoint-exposer/commit/e7e86c6fbb93a73609a4cf4ae417e72b2ab196d0))
* **istio:** read context from NP_ACTION_CONTEXT + omit empty claim `when` ([#13](https://github.com/nullplatform/services-endpoint-exposer/issues/13)) ([0c1346b](https://github.com/nullplatform/services-endpoint-exposer/commit/0c1346bc3a84371594c918cc5a23cc3e611e4cd2))
* **istio:** read notification context from NP_ACTION_CONTEXT; omit empty claim when ([f6f205f](https://github.com/nullplatform/services-endpoint-exposer/commit/f6f205f2df1e8d84b3d641e6e17d97a69dac4e4d))

## [0.2.1](https://github.com/nullplatform/services-endpoint-exposer/compare/v0.2.0...v0.2.1) (2026-07-13)


### Bug Fixes

* **istio:** allow reading Cognito JWT from a cookie ([2fb7f11](https://github.com/nullplatform/services-endpoint-exposer/commit/2fb7f119663ba0c1fd2c0ffb367112c9db4af91f))

## [0.2.0](https://github.com/nullplatform/services-endpoint-exposer/compare/v0.1.0...v0.2.0) (2026-07-08)


### Features

* **tofu:** add install and requirements/aws OpenTofu modules ([dfcf6ff](https://github.com/nullplatform/services-endpoint-exposer/commit/dfcf6ff4d9f1f3dc9fe1e8f70eff0b9331202807))

## [0.1.0](https://github.com/nullplatform/services-endpoint-exposer/compare/0.0.1...v0.1.0) (2026-07-06)


### Features

* endpoint exposer v2 - Istio HTTPRoute with Cognito/AVP auth ([dd5e6f4](https://github.com/nullplatform/services-endpoint-exposer/commit/dd5e6f423b16dc1dd0b2548ee62de9e2c93582dd))
* **endpoint-exposer:** initial implementation ([4c10445](https://github.com/nullplatform/services-endpoint-exposer/commit/4c10445643f012b35721b4d07266a917fb4eca77))


### Bug Fixes

* **service-spec:** add visibility dropdown, scope description, and groups pills ([889fa98](https://github.com/nullplatform/services-endpoint-exposer/commit/889fa98578ca102e5b79ab5dc5af1254d47d8277))
* **service-spec:** fix asterisk indicators on Routes and Authorized Groups labels ([b70f5b7](https://github.com/nullplatform/services-endpoint-exposer/commit/b70f5b75cb51cc258769158459ab2f07234835eb))
* **service-spec:** fix asterisk indicators on Routes and Authorized Groups labels ([dfc03b7](https://github.com/nullplatform/services-endpoint-exposer/commit/dfc03b7b8c87fb95996dbcb957a7b0a8b3bff60a))
* **service-spec:** improve route form UX with scope description and groups pills ([98fda69](https://github.com/nullplatform/services-endpoint-exposer/commit/98fda69196d8139a6758edc17ce792621269dafa))
* **service-spec:** remove visibility field, revert scope enum to show all scopes ([3d9c641](https://github.com/nullplatform/services-endpoint-exposer/commit/3d9c6418e45c817603af2ae06ab39cc7fc9b7d2c))
* **service-spec:** try dynamic scope filtering by visibility form value ([e86ff54](https://github.com/nullplatform/services-endpoint-exposer/commit/e86ff54dbe48c7d5a4412f5062c0d1c252facfd8))
