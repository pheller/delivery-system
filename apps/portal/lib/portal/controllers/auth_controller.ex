defmodule Prodigy.Portal.AuthController do
  use Prodigy.Portal, :controller

  alias Prodigy.Portal.UserManager
  alias Prodigy.Portal.UserManager.Guardian

  plug Ueberauth

  def request(conn, _params) do
    # render(conn, "request.html", callback_url: Helpers.callback_url(conn))
    conn
  end

  def callback(%{assigns: %{ueberauth_auth: %{provider: :github} = auth}} = conn, _params) do
    %{uid: uid, info: %{email: email}} = auth

    {:ok, user} =
      UserManager.get_or_create(%{provider_uid: uid, provider: :github, username: email})

    conn
    |> Guardian.Plug.sign_in(user, %{role: :user})
    |> put_flash(:info, "Successfully authenticated.")
    |> configure_session(renew: true)
    |> redirect(to: "/")
  end

  def callback(conn, _) do
    error = "Unexpected auth response"

    IO.puts(error)

    conn
    |> put_flash(:error, error)
    |> redirect(to: "/")
  end
end
