defmodule AnimeWeb.LocaleTest do
  use ExUnit.Case, async: true
  alias AnimeWeb.Locale

  test "preference priority is user, valid cookie, language header, Russian fallback" do
    assert Locale.preferred(%{locale: :ru}, %{"locale" => "en"}, ["en"]) == "ru"
    assert Locale.preferred(%{locale: :en}, %{"locale" => "ru"}, ["ru"]) == "en"
    assert Locale.preferred(nil, %{"locale" => "ru"}, ["en"]) == "ru"
    assert Locale.preferred(nil, %{"locale" => "de"}, ["en-US"]) == "en"
    assert Locale.preferred(nil, %{}, []) == "ru"
    assert Locale.preferred(nil, %{}, ["de,fr;q=0.9"]) == "ru"
  end

  test "Accept-Language respects quality, order, regional tags and exclusions" do
    for {headers, expected} <- [
          {["de, en-US;q=0.8, ru-RU;q=0.9"], "ru"},
          {["EN-gb; Q=0.9, ru;q=0.8"], "en"},
          {["en;q=0.7,ru;q=0.7"], "en"},
          {["ru;q=0.7,en;q=0.7"], "ru"},
          {["ru;q=0", "en;q=0.5"], "en"},
          {["en;q=0,ru;q=1"], "ru"},
          {["*,en;q=0.9"], "en"},
          {["en;q=1.000,ru;q=0.999"], "en"}
        ] do
      assert Locale.from_accept_language(headers) == expected
    end
  end

  test "malformed ranges and qualities are not accepted as a language preference" do
    for bad <- [
          "enough",
          "en_US",
          "en;q=2",
          "en;q=-1",
          "en;q=oops",
          "en;q=0.1234",
          "en;q=0.5;q=1",
          "en;q=1.001",
          "en;q="
        ] do
      assert Locale.from_accept_language([bad]) == "ru"
    end
  end

  test "locale paths preserve query strings and are idempotent" do
    for {locale, value, expected} <- [
          {"en", "/", "/en"},
          {"en", "/?q=tv", "/en?q=tv"},
          {"ru", "/en?page=2", "/?page=2"},
          {"en", "/catalog?genre[]=1&genre[]=2&page=2", "/en/catalog?genre[]=1&genre[]=2&page=2"},
          {"en", "/en/profile/settings", "/en/profile/settings"},
          {"ru", "/en/password/reset/token", "/password/reset/token"},
          {"ru", "/enough", "/enough"}
        ] do
      assert Locale.localized(locale, value) == expected
      assert Locale.switch_path(locale, value) == expected
    end
  end

  test "service routes never acquire a locale prefix" do
    for path <- [
          "/admin",
          "/admin/users?page=2",
          "/locale",
          "/logout",
          "/healthz",
          "/readyz",
          "/robots.txt"
        ] do
      assert Locale.localized("en", path) == path
    end

    refute Locale.service?("/administrator")
    refute Locale.service?("/en/catalog")
  end

  test "switch validates the stripped path too, and never redirects to an external origin" do
    for value <- [
          nil,
          %{},
          "https://evil.example",
          "//evil.example",
          "/en//evil.example",
          "/en/%2Fevil.example",
          "/en/%5Cevil.example",
          "/admin/users",
          "/en/admin/users",
          "/ok%0d%0aLocation:x",
          "/" <> String.duplicate("x", 512)
        ] do
      assert Locale.switch_path("ru", value) == "/"
      assert Locale.switch_path("en", value) == "/en"
    end
  end

  test "current page includes the original query, not the origin or fragment" do
    url = "https://example.test/en/catalog?genre[]=1&q=a%26b#ignored"
    assert Locale.current_path(url) == "/en/catalog?genre[]=1&q=a%26b"
    assert Locale.current_path(Plug.Test.conn(:get, url)) == "/en/catalog?genre[]=1&q=a%26b"
  end
end
