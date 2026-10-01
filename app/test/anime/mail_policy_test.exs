defmodule Anime.MailPolicyTest do
  use Anime.DataCase
  alias Anime.MailPolicy

  setup do
    previous =
      for key <- [:app_env, :staging_mail_allowlist, :mail_return_path],
          do: {key, Application.fetch_env(:anime, key)}

    on_exit(fn ->
      for {key, value} <- previous do
        case value do
          {:ok, val} -> Application.put_env(:anime, key, val)
          :error -> Application.delete_env(:anime, key)
        end
      end
    end)

    Application.put_env(:anime, :mail_return_path, "bounce@localhost")
    :ok
  end

  test "parses exact case-insensitive addresses, never wildcards or domains" do
    assert MailPolicy.parse!(" A@example.test, a@EXAMPLE.test,b@example.test ") ==
             MapSet.new(["a@example.test", "b@example.test"])

    for value <- [
          nil,
          "",
          " ",
          "@example.test",
          "*@example.test",
          "a@example.test,",
          "a@example.test\r\nBcc: private@example.test",
          "private-secret"
        ] do
      error = assert_raise ArgumentError, fn -> MailPolicy.parse!(value) end
      refute Exception.message(error) =~ "private"
    end
  end

  test "staging fails closed and uses exact addresses rather than suffixes" do
    Application.put_env(:anime, :app_env, "staging")
    Application.delete_env(:anime, :staging_mail_allowlist)
    refute MailPolicy.allowed?("a@example.test")
    Application.put_env(:anime, :staging_mail_allowlist, MailPolicy.parse!("a@example.test"))
    assert MailPolicy.allowed?("A@EXAMPLE.test")
    refute MailPolicy.allowed?("other@example.test")
    refute MailPolicy.allowed?("a@example.test.evil.test")
    refute MailPolicy.allowed?("a+tag@example.test")
  end

  test "disallowed real mail job succeeds without reaching the adapter" do
    u = user()
    Application.put_env(:anime, :app_env, "staging")
    Application.put_env(:anime, :staging_mail_allowlist, MailPolicy.parse!("other@example.test"))
    assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :mailers)
    refute_received {:email, _}
    assert Repo.get!(Anime.Accounts.User, u.id).status == u.status
    refute Repo.exists?(from a in Anime.Audit, where: a.action == "mail_delivery_failed")
  end

  test "allowlisted real mail job reaches the test adapter" do
    u = user()
    Application.put_env(:anime, :app_env, "staging")
    Application.put_env(:anime, :staging_mail_allowlist, MailPolicy.parse!(u.email))
    assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :mailers)
    assert_received {:email, %Swoosh.Email{to: [{_, address}]}}
    assert address == u.email
  end

  test "unknown environment is denied while dev prod and test are unchanged" do
    for environment <- ["dev", "prod", "test"] do
      Application.put_env(:anime, :app_env, environment)
      assert MailPolicy.allowed?("a@example.test")
    end

    Application.delete_env(:anime, :app_env)
    refute MailPolicy.allowed?("a@example.test")
  end
end
