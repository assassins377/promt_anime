defmodule AnimeWeb.PlaceholderLive do
  use AnimeWeb, :live_view
  def mount(_, _, socket), do: {:ok, socket}

  def handle_params(_, _, socket),
    do:
      {:noreply,
       assign(socket, :page_title, AnimeWeb.PageTitles.placeholder(socket.assigns.live_action))}

  def handle_info(:access_changed, socket), do: {:noreply, redirect(socket, to: "/")}

  def render(assigns) do
    ~H"""
    <section class="empty-state">
      <span class="eyebrow">ANIME · {gettext("В разработке")}</span><h1>
        {gettext("Раздел появится позже")}
      </h1><p>
        {gettext(
          "Сейчас доступен первый срез: регистрация, вход и аккаунт. Контент добавляется следующими очередями."
        )}
      </p><a
        class="button"
        href={AnimeWeb.Auth.localized(@locale, if(@current_user, do: "/profile", else: "/register"))}
      >{gettext("Мой аккаунт")} →</a>
    </section>
    """
  end
end
