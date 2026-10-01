defmodule AnimeWeb.AdminFormatTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest
  alias AnimeWeb.{AdminFormat, AdminComponents}

  test "language changes presentation, not the timestamp or UTC tooltip" do
    dt = ~U[2026-09-28 14:30:12.345678Z]
    ru = AdminFormat.datetime(dt, "ru")
    en = AdminFormat.datetime(dt, "en")
    assert ru.text == "28.09.2026 14:30 UTC"
    assert en.text == "Sep 28, 2026, 14:30 UTC"
    assert ru.iso == en.iso
    assert ru.iso == "2026-09-28T14:30:12.345678Z"
    assert ru.title == en.title
    assert en.title == ru.iso <> " (UTC)"
    assert AdminFormat.datetime(dt, "en", true).text == "Sep 28, 2026, 14:30:12 UTC"
  end

  test "audit ISO strings are normalized to UTC; missing and invalid values stay absent" do
    assert AdminFormat.datetime("2026-09-28T23:30:12.345678+09:00", "ru").iso ==
             "2026-09-28T14:30:12.345678Z"

    for value <- [nil, "not a date", "<script>alert(1)</script>"] do
      assert AdminFormat.datetime(value, "en") == nil
      html = render_component(&AdminComponents.admin_datetime/1, value: value, locale: "en")
      refute html =~ "<time"
      refute html =~ "script"
      assert html =~ "—"
    end
  end

  test "time markup retains exact machine value and a readable UTC tooltip" do
    html =
      render_component(&AdminComponents.admin_datetime/1,
        value: ~U[2026-09-28 14:30:12.345678Z],
        locale: "en",
        seconds: true
      )

    assert html =~ ~s(datetime="2026-09-28T14:30:12.345678Z")
    assert html =~ ~s(title="2026-09-28T14:30:12.345678Z \(UTC\)")
    assert html =~ "Sep 28, 2026, 14:30:12 UTC"

    assert render_component(&AdminComponents.admin_datetime/1,
             value: nil,
             locale: "en",
             empty: "Permanent"
           ) =~ "Permanent"
  end

  test "integer grouping is localized without rounding or changing page URLs" do
    for {value, ru, en} <- [
          {0, "0", "0"},
          {999, "999", "999"},
          {1_234_567, "1 234 567", "1,234,567"},
          {-1000, "-1 000", "-1,000"}
        ] do
      assert AdminFormat.number(value, "ru") == ru
      assert AdminFormat.number(value, "en") == en
    end

    for {locale, display} <- [{"ru", "1 001"}, {"en", "1,001"}] do
      html =
        render_component(&AdminComponents.pagination/1,
          listing: %{page: 1000, pages: 1001},
          query: %{},
          path: "/admin/users",
          locale: locale
        )

      assert html =~ display
      assert html =~ ~s(href="/admin/users?page=1001")
      refute html =~ "page=1,001"
    end
  end
end
