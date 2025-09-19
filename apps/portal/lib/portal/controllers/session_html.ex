defmodule Prodigy.Portal.SessionHTML do
  use Prodigy.Portal, :html

  def new(assigns) do
    ~H"""
    <div class="max-w-md m-20">
      <header class="font-bold">Login to an existing account</header>

      <.simple_form for={@form} action={~p"/login"}>
        <.input field={@form[:username]} label="Username" />
        <.input field={@form[:password]} label="Password" type="password" id="password-input" />
        <div class="flex flex-row gap-2">
          <.input type="checkbox"autocomplete="off" name="password-visibility" phx-click={JS.toggle_attribute({"type", "password", "text"}, to: "#password-input")} />
          <.icon name="hero-eye" />
        </div>
        <:actions>
          <.button>Login</.button>
        </:actions>
      </.simple_form>

      <div class="my-16">
        <span>Not yet set up?</span>
        <.button_link href="/register">Create new account instead</.button_link>
      </div>
    </div>
    """
  end
end
