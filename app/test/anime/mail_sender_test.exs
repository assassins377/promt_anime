defmodule Anime.MailSenderTest do
  use Anime.DataCase
  alias Anime.MailSender

  setup do
    previous = Application.fetch_env(:anime, :mail_return_path)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:anime, :mail_return_path, value)
        :error -> Application.delete_env(:anime, :mail_return_path)
      end
    end)

    :ok
  end

  test "return path controls SMTP envelope without Reply-To or forged Return-Path" do
    Application.put_env(:anime, :mail_return_path, "bounce@example.test")

    email =
      Swoosh.Email.new()
      |> Swoosh.Email.from({"Anime", "notice@example.test"})
      |> MailSender.envelope()

    assert Swoosh.Adapters.SMTP.Helpers.sender(email) == "bounce@example.test"
    assert email.from == {"Anime", "notice@example.test"}
    refute Map.has_key?(email.headers, "Return-Path")
    assert email.reply_to == nil

    Application.put_env(:anime, :mail_return_path, "bounce@foreign.test")
    assert_raise ArgumentError, fn -> MailSender.envelope(email) end
    Application.put_env(:anime, :mail_return_path, "bounce@sub.example.test")
    assert_raise ArgumentError, fn -> MailSender.envelope(email) end
  end

  test "allows the site domain and real subdomains, not suffix lookalikes" do
    assert {:ok, {"Аниме", "no-reply@example.test"}} =
             MailSender.validate("Аниме", "no-reply@EXAMPLE.test", "example.test")

    assert {:ok, _} = MailSender.validate("Anime", "no-reply@mail.example.test", "example.test")

    for domain <- [
          "evil-example.test",
          "example.test.evil.test",
          "foreign.test",
          "-mail.example.test"
        ] do
      assert {:error, :invalid_mail_sender} =
               MailSender.validate("Anime", "a@" <> domain, "example.test")
    end
  end

  test "rejects missing, malformed and injected sender values without exposing them" do
    for {name, address} <- [
          {nil, nil},
          {"", "a@example.test"},
          {String.duplicate("a", 65), "a@example.test"},
          {"Anime\r\nPRIVATE", "a@example.test"},
          {"Anime", "a@example.test\r\nBcc:PRIVATE"},
          {"Anime", "a@@example.test"},
          {"Anime", ".a@example.test"},
          {"Anime", "a..b@example.test"}
        ] do
      assert {:error, :invalid_mail_sender} = MailSender.validate(name, address, "example.test")
    end
  end

  test "real queued mail reads the current sender settings" do
    user()
    set("email_from_name", "Локальная проверка")
    set("email_from_address", "notice@mail.localhost")
    assert %{success: 1} = Oban.drain_queue(queue: :mailers)
    assert_received {:email, %Swoosh.Email{from: {"Локальная проверка", "notice@mail.localhost"}}}
  end

  test "foreign configured sender never reaches the transport" do
    user()
    set("email_from_address", "private@foreign.test")
    assert %{failure: 1} = Oban.drain_queue(queue: :mailers)
    refute_received {:email, _}
    job = Repo.one!(Oban.Job)
    assert job.state == "retryable"
    refute inspect(job.errors) =~ "private@foreign.test"
    assert inspect(job.errors) =~ "invalid_mail_sender"
  end

  defp set(key, value) do
    Repo.update_all(from(s in Anime.Settings.Setting, where: s.key == ^key), set: [value: value])
  end
end
