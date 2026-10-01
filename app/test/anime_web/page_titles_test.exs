defmodule AnimeWeb.PageTitlesTest do
  use AnimeWeb.ConnCase

  defp title(html),
    do: html |> LazyHTML.from_document() |> LazyHTML.query("title") |> LazyHTML.text()

  test "authentication titles distinguish pages in both locales", %{conn: conn} do
    for {path, expected} <- [
          {"/login", "Вход"},
          {"/register", "Регистрация"},
          {"/password/reset", "Восстановление пароля"},
          {"/password/reset/private-token", "Новый пароль"},
          {"/en/login", "Sign in"},
          {"/en/register", "Register"},
          {"/en/password/reset", "Reset your password"},
          {"/en/password/reset/private-token", "New password"}
        ] do
      html = conn |> get(path) |> html_response(200)
      assert title(html) == expected <> " · Anime"
      refute title(html) =~ "private-token"
      assert html =~ ~s(content="noindex,nofollow")
    end
  end

  test "profile and password change have their own titles", %{conn: conn} do
    conn = login_conn(conn, user())

    for {path, expected} <- [
          {"/profile", "Мой профиль"},
          {"/profile/settings", "Настройки"},
          {"/password/change", "Смена пароля"},
          {"/en/profile", "My profile"},
          {"/en/profile/settings", "Settings"},
          {"/en/password/change", "Change password"}
        ] do
      assert title(html_response(get(conn, path), 200)) == expected <> " · Anime"
    end
  end

  test "connected navigation updates the title", %{conn: conn} do
    {:ok, view, _} = live(login_conn(conn, user()), "/profile")
    assert page_title(view) == "Мой профиль · Anime"
    render_patch(view, "/profile/settings")
    assert page_title(view) == "Настройки · Anime"
    render_patch(view, "/profile")
    assert page_title(view) == "Мой профиль · Anime"
  end

  test "future pages identify themselves as work in progress", %{conn: conn} do
    for {path, expected} <- [
          {"/", "Главная · В разработке"},
          {"/catalog/tv", "Каталог · В разработке"},
          {"/en/catalog", "Catalog · In development"},
          {"/en/donate", "Donations · In development"},
          {"/terms", "Условия использования · В разработке"}
        ] do
      assert title(html_response(get(conn, path), 200)) == expected <> " · Anime"
    end
  end
end
