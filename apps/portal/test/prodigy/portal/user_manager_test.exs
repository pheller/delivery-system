defmodule Prodigy.Portal.UserManagerTests do
  use Prodigy.Portal.RepoCase, async: true

  alias Pbkdf2
  alias Prodigy.Portal.UserManager
  alias Prodigy.Core.Data.Portal.User, as: PortalUser

  @valid_attrs %{
    username: "some username",
    password: "some password"
  }

  test "create_user/1 with valid data creates a user" do
    assert {:ok, %PortalUser{} = user} = UserManager.create_user(@valid_attrs)
    assert {:ok, user} == Pbkdf2.check_pass(user, "some password", hash_key: :password)
    assert user.username == "some username"
  end
end