// forge-app's browser-side online controller (web-only).
//
// M0 skeleton: it imports the atproto-monad surface the sign-in overlay will
// drive, so the wasm build proves the browser graph links. The model, effects
// and view arrive in M2.

use atproto_common::jws {Atp.s256}
use atproto_oauth::client_metadata {Atp.ClientConfig}
use atproto_oauth::persist {Atp.pending_key, Atp.session_key}
use atproto_web::web {Atp.begin_sign_in}
use forge_online::identity {Provider, provider_name}

pub def online_contract_version : I64 := 1

pub def online_provider_smoke : String := provider_name Provider.atproto
