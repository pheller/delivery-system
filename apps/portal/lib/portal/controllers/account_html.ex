defmodule Prodigy.Portal.AccountHTML do
  use Prodigy.Portal, :html

  def show(assigns) do
    ~H"""
    <div class="m-10 flex flex-col gap-10">
      <h2>Hello, {@current_user.username}</h2>
      <.button_link href="/logout" class="w-fit">Logout</.button_link>
    </div>
    """
  end
end
