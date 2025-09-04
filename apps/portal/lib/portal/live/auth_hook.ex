defmodule Portal.Live.AuthHook do

  import Phoenix.Component

  alias Prodigy.Portal.UserManager

  def on_mount(:assign_current_user, _params, session, socket) do
    user = case session["user_id"] do
      nil -> nil
      id -> UserManager.get_user!(id)
    end

    {:cont, assign(socket, :current_user, user)}
  end
end