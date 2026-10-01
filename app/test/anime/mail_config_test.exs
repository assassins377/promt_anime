defmodule Anime.MailConfigTest do
  use ExUnit.Case, async: true
  alias Anime.MailConfig

  defp env do
    %{
      "SMTP_HOST" => "smtp.example.test",
      "SMTP_USERNAME" => "private-user",
      "SMTP_PASSWORD" => "private-secret",
      "MAIL_RETURN_PATH" => "bounce@example.test"
    }
  end

  test "SMTP defaults require authenticated STARTTLS, certificate and hostname verification, no retries" do
    config = MailConfig.load!(env(), "staging", "example.test")
    assert config.adapter == :smtp
    assert config.return_path == "bounce@example.test"
    opts = config.options
    assert opts[:adapter] == Swoosh.Adapters.SMTP
    assert opts[:port] == 587
    assert opts[:auth] == :always
    assert opts[:tls] == :always
    refute opts[:ssl]
    assert opts[:retries] == 0
    assert opts[:no_mx_lookups]
    assert opts[:tls_options][:verify] == :verify_peer
    assert opts[:tls_options][:cacerts] != []
    assert opts[:tls_options][:server_name_indication] == ~c"smtp.example.test"
    assert is_function(opts[:tls_options][:customize_hostname_check][:match_fun], 2)
    refute inspect(config) =~ "private"
    refute inspect(config) =~ "bounce"
  end

  test "missing malformed and injected configuration has redacted diagnostics" do
    for key <- ~w(SMTP_HOST SMTP_USERNAME SMTP_PASSWORD MAIL_RETURN_PATH),
        value <- [nil, "", "private\r\nsecret", <<255>>] do
      error =
        assert_raise ArgumentError, fn ->
          MailConfig.load!(Map.put(env(), key, value), "prod", "example.test")
        end

      assert Exception.message(error) =~ key
      refute Exception.message(error) =~ "private"
    end

    for {key, value} <- [
          {"SMTP_PORT", "0"},
          {"SMTP_PORT", "65536"},
          {"SMTP_PORT", "587x"},
          {"SMTP_TLS", "if_available"},
          {"SMTP_HOST", "https://smtp.example.test"},
          {"MAIL_RETURN_PATH", "bounce@foreign.test"}
        ] do
      assert_raise ArgumentError, fn ->
        MailConfig.load!(Map.put(env(), key, value), "prod", "example.test")
      end
    end
  end

  test "dev and test never silently select SMTP, staging never silently selects local" do
    assert MailConfig.load!(%{}, "dev", "localhost").adapter == :local
    assert MailConfig.load!(%{}, "test", "localhost").adapter == :test

    for {environment, adapter} <- [
          {"dev", "smtp"},
          {"test", "smtp"},
          {"staging", "local"},
          {"prod", "test"}
        ] do
      assert_raise ArgumentError, fn ->
        MailConfig.load!(%{"MAIL_ADAPTER" => adapter}, environment, "example.test")
      end
    end
  end

  test "explicit TLS never follows the specified switch instead of silently changing it" do
    config = MailConfig.load!(Map.put(env(), "SMTP_TLS", "never"), "prod", "example.test")
    assert config.options[:tls] == :never
  end
end
