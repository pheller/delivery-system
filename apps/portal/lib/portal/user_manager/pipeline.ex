defmodule Prodigy.Portal.UserManager.Pipeline do
  use Guardian.Plug.Pipeline,
    otp_app: :portal,
    error_handler: Prodigy.Portal.UserManager.ErrorHandler,
    module: Prodigy.Portal.UserManager.Guardian

  # If there is a session token, restrict it to an access token and validate it
  plug Guardian.Plug.VerifySession, claims: %{"typ" => "access"}
  # If there is an authorization header, restrict it to an access token and validate it
  plug Guardian.Plug.VerifyHeader, claims: %{"typ" => "access"}
  # Load the user if either of the verifications worked
  plug Guardian.Plug.LoadResource, allow_blank: true
  # assign current_user if authenticated
  plug :current_user

  defp current_user(conn, _opts) do
    assign(conn, :current_user, Guardian.Plug.current_resource(conn))
  end
end
