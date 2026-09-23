# Copyright 2026, Phillip Heller
#
# This file is part of Prodigy Reloaded.
#
# Prodigy Reloaded is free software: you can redistribute it and/or modify it under the terms of the GNU Affero General
# Public License as published by the Free Software Foundation, either version 3 of the License, or (at your
# option) any later version.
#
# Prodigy Reloaded is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even
# the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License along with Prodigy Reloaded. If not,
# see <https://www.gnu.org/licenses/>.

defmodule Prodigy.Portal.InvitationControllerTest do
  use Prodigy.Portal.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Prodigy.Portal.AccountsFixtures

  alias Prodigy.Core.Data.Portal.User
  alias Prodigy.Core.Data.Portal.UserToken
  alias Prodigy.Core.Data.Repo
  alias Prodigy.Portal.Accounts
  alias Prodigy.Portal.Accounts.{Blacklist, RateLimit}

  setup do
    RateLimit.reset()
    :ok
  end

  describe "GET /users/confirm/:token" do
    test "signup_invitation token creates + logs in + deletes token", %{conn: conn} do
      email = "c-#{System.unique_integer([:positive])}@example.com"
      {encoded, token} = UserToken.build_signup_invitation_token(email)
      Repo.insert!(token)

      conn = get(conn, ~p"/users/confirm/#{encoded}")

      assert redirected_to(conn) == ~p"/"
      assert get_session(conn, :user_token)
      assert Accounts.get_user_by_email(email)
      refute Repo.get_by(UserToken, sent_to: email, context: "signup_invitation")
    end

    test "provider_link_invitation token attaches + logs in", %{conn: conn} do
      user = user_fixture()

      {encoded, token} =
        UserToken.build_provider_link_invitation_token(user, :google, "g-link")

      Repo.insert!(token)

      conn = get(conn, ~p"/users/confirm/#{encoded}")

      assert redirected_to(conn) == ~p"/"
      assert [%{provider: :google, provider_uid: "g-link"}] = Accounts.list_identities(user)
    end

    test "bad / expired token renders the generic invalid-link page", %{conn: conn} do
      conn = get(conn, ~p"/users/confirm/not-a-real-token")
      assert response(conn, 200) =~ "Link expired or invalid"
    end

    # Regression: two live signup tokens for one address (a duplicate form
    # submit, or a mail scanner prefetching the first link). The second click
    # used to raise CaseClauseError on register_user's uniqueness failure and
    # return a 500.
    test "a second live signup token for the same address logs in, no 500", %{conn: conn} do
      email = "dup-#{System.unique_integer([:positive])}@example.com"
      {encoded_a, token_a} = UserToken.build_signup_invitation_token(email)
      Repo.insert!(token_a)
      {encoded_b, token_b} = UserToken.build_signup_invitation_token(email)
      Repo.insert!(token_b)

      conn_a = get(conn, ~p"/users/confirm/#{encoded_a}")
      assert redirected_to(conn_a) == ~p"/"
      user = Accounts.get_user_by_email(email)
      assert user

      conn_b = get(build_conn(), ~p"/users/confirm/#{encoded_b}")

      assert redirected_to(conn_b) == ~p"/"
      assert get_session(conn_b, :user_token)
      # Same account, not a second registration.
      assert Accounts.get_user_by_email(email).id == user.id
      assert Repo.aggregate(from(u in User, where: u.email == ^email), :count) == 1
      # Both tokens burned.
      refute Repo.get_by(UserToken, sent_to: email, context: "signup_invitation")
    end

    test "signup token for an address registered via OAuth meanwhile logs in", %{conn: conn} do
      email = "oauth-#{System.unique_integer([:positive])}@example.com"
      {encoded, token} = UserToken.build_signup_invitation_token(email)
      Repo.insert!(token)

      # Account appears between mint and click.
      {:logged_in, user} =
        Accounts.process_oauth_callback(:google, "g-#{System.unique_integer([:positive])}", email)

      conn = get(conn, ~p"/users/confirm/#{encoded}")

      assert redirected_to(conn) == ~p"/"
      assert get_session(conn, :user_token)
      assert Accounts.get_user_by_email(email).id == user.id
    end

    test "unconfirmed account with a password set is not logged in from the link", %{conn: conn} do
      user = unconfirmed_user_fixture()
      set_password(user)

      {encoded, token} = UserToken.build_signup_invitation_token(user.email)
      Repo.insert!(token)

      conn = get(conn, ~p"/users/confirm/#{encoded}")

      # phx.gen.auth session-fixation guard: generic page, no session.
      assert response(conn, 200) =~ "Link expired or invalid"
      refute get_session(conn, :user_token)
      refute Accounts.get_user_by_email(user.email).confirmed_at
    end
  end

  describe "GET /users/dismiss/:token" do
    test "blacklists the email and deletes the token", %{conn: conn} do
      email = "d-#{System.unique_integer([:positive])}@example.com"
      {encoded, token} = UserToken.build_signup_invitation_token(email)
      Repo.insert!(token)

      conn = get(conn, ~p"/users/dismiss/#{encoded}")

      assert response(conn, 200) =~ "Request cancelled"
      refute Repo.get_by(UserToken, sent_to: email)
      assert Blacklist.blacklisted?(email)
    end

    test "unknown token still renders the uniform dismissed page", %{conn: conn} do
      conn = get(conn, ~p"/users/dismiss/not-a-real-token")
      assert response(conn, 200) =~ "Request cancelled"
    end

    # The blacklist is consulted by request_access/3, which drops blacklisted
    # addresses silently - blacklisting a live account disables its magic-link
    # login for 30 days with no visible error and no admin UI to undo it.
    test "does not blacklist an address that already has an account", %{conn: conn} do
      user = user_fixture()
      {encoded, token} = UserToken.build_signup_invitation_token(user.email)
      Repo.insert!(token)

      conn = get(conn, ~p"/users/dismiss/#{encoded}")

      assert response(conn, 200) =~ "Request cancelled"
      refute Repo.get_by(UserToken, sent_to: user.email, context: "signup_invitation")
      refute Blacklist.blacklisted?(user.email)
    end

    # Provider-link tokens are minted against an existing user by definition,
    # so this path would otherwise blacklist the account owner every time.
    test "provider-link dismissal does not blacklist the account owner", %{conn: conn} do
      user = user_fixture()

      {encoded, token} =
        UserToken.build_provider_link_invitation_token(user, :google, "g-dismiss")

      Repo.insert!(token)

      conn = get(conn, ~p"/users/dismiss/#{encoded}")

      assert response(conn, 200) =~ "Request cancelled"
      refute Repo.get_by(UserToken, user_id: user.id, context: "provider_link_invitation")
      refute Blacklist.blacklisted?(user.email)
      # The provider was not linked - dismissal still refuses the link.
      assert Accounts.list_identities(user) == []
    end
  end
end
