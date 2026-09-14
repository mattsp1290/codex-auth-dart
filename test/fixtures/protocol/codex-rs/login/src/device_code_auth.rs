format!("{auth_base_url}/deviceauth/usercode")
format!("{auth_base_url}/deviceauth/token")
device_auth_id: uc.device_auth_id
user_code: uc.user_code
code_verifier: code_resp.code_verifier
&code_resp.authorization_code
Duration::from_secs(15 * 60)
format!("{base_url}/deviceauth/callback")
