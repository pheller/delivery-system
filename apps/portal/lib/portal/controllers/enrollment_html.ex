defmodule Prodigy.Portal.EnrollmentHTML do
  use Prodigy.Portal, :html

  def new(assigns) do
    ~H"""
    <div class="flex flex-col justify-center items-center gap-4">
      <div class="font-semibold text-xl m-10">
        Sign up for Prodigy Reloaded by signing in with one of the following
        service providers. Pick one, then click it's icon to get started.
      </div>

      <div>
        <.button_link href="/auth/github">Github</.button_link>
      </div>
    </div>
    """
  end
end
