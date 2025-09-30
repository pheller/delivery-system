defmodule Prodigy.Portal.AuthControllerTest do
  use Prodigy.Portal.ConnCase, async: true

  alias Prodigy.Core.Data.Repo
  alias Prodigy.Core.Data.Portal.User, as: PortalUser

  test "/auth callback from github creates new user", %{conn: conn} do
    provider_uid = 12345

    refute Repo.get_by(PortalUser, %{provider_uid: provider_uid})

    auth = %Ueberauth.Auth{
      uid: provider_uid,
      provider: :github,
      info: %Ueberauth.Auth.Info{
        email: "email@example.com",
      }
    }


    conn =
      conn
      |> assign(:ueberauth_auth, auth)
      |> get("/auth/github/callback")

    assert redirected_to(conn) == "/"
    assert get_session(conn, :user_id)

    assert user = Repo.get_by(PortalUser, %{provider_uid: provider_uid})
    assert user.provider == :github
    assert user.username == "email@example.com"
  end

  # TODO ...
#  test "/auth callback logs in existing user", %{conn: conn} do
#    provider_uid = 12345
#
#    existing_user = Repo.insert!(%PortalUser{
#      provider_uid: provider_uid,
#      provider: :github,
#      username: "existing@example.com"
#    })
#
#
#
#  end

end
