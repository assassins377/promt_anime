defmodule Anime.Queue1AcceptanceTest do
  use Anime.DataCase
  import Swoosh.TestAssertions
  alias Anime.{Accounts, Settings}
  alias Anime.Accounts.{Tokens, UserToken}
  alias Anime.Workers.Mail

  test "password reset email, one-use link, session revocation and security notice form one flow" do
    u = user(%{"locale" => "en"})
    {:ok, {session, remember}} = Accounts.create_session(u, true, meta())
    assert :ok = Accounts.request_reset(u.email)

    token =
      Repo.one!(from t in UserToken, where: t.user_id == ^u.id and t.context == :reset_password)

    job =
      Repo.one!(
        from j in Oban.Job, where: fragment("?->>'token_id'", j.args) == ^to_string(token.id)
      )

    assert :ok = Mail.perform(job)
    raw = Base.url_encode64(Tokens.mail_bytes(token), padding: false)
    origin = Application.fetch_env!(:anime, :site_origin)

    assert_email_sent(fn email ->
      assert email.to == [{"", u.email}]
      assert email.text_body =~ origin <> "/en/password/reset/" <> raw
      refute email.text_body =~ "InitialExample123"
      true
    end)

    credentials = %{
      "password" => "ResetAcceptance456!",
      "password_confirmation" => "ResetAcceptance456!"
    }

    assert {:ok, _} = Accounts.reset_password(raw, credentials, meta())
    refute Tokens.user(session)
    refute Tokens.find(remember, [:remember_me])
    assert {:error, :invalid_token} = Accounts.reset_password(raw, credentials, meta())
    assert {:ok, _} = Accounts.authenticate(u.email, credentials["password"], meta())

    notice =
      Repo.one!(from j in Oban.Job, where: fragment("?->>'kind'", j.args) == "password_changed")

    assert :ok = Mail.perform(notice)

    assert_email_sent(fn email ->
      assert email.to == [{"", u.email}]
      assert email.subject == "Password changed"
      refute email.text_body =~ credentials["password"]
      refute email.text_body =~ raw
      true
    end)
  end

  test "password notice for a deleted user is safely discarded without mail" do
    u = user()
    Repo.delete!(u)

    assert :ok =
             Mail.perform(%Oban.Job{
               args: %{"user_id" => u.id, "kind" => "password_changed", "locale" => "ru"}
             })

    refute_email_sent()
  end

  test "email-change notice without its audit entry is discarded without mail" do
    assert :ok =
             Mail.perform(%Oban.Job{
               args: %{"audit_id" => 0, "kind" => "email_change_notice", "locale" => "ru"}
             })

    refute_email_sent()
  end

  test "a session token cannot be used as an email-confirmation job" do
    u = user()
    {:ok, {raw, _}} = Accounts.create_session(u, false, meta())
    token = Tokens.find(raw, [:session])
    assert :ok = Mail.perform(%Oban.Job{args: %{"token_id" => token.id, "locale" => "ru"}})
    refute_email_sent()
    assert Tokens.user(raw).id == u.id
  end

  test "missing settings use only the caller fallback; JSON defaults are decoded" do
    assert Settings.get("missing_queue1_setting") == nil
    assert Settings.get("missing_queue1_setting", "fallback") == "fallback"
    assert Settings.get("cron_disabled_workers") == []
    assert Settings.get("catalog_per_page") == 30
    assert Settings.get("registration_enabled") == true
    assert Settings.get("site_name") == "Anime"
  end
end
