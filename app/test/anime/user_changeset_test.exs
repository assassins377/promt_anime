defmodule Anime.UserChangesetTest do
  use ExUnit.Case, async: true
  alias Anime.Accounts.User
  alias Ecto.Changeset

  test "inspecting user data redacts password and hash fields" do
    user = %User{
      nick: "visible-reader",
      password: "PRIVATE-PLAIN",
      password_confirmation: "PRIVATE-CONFIRM",
      hashed_password: "PRIVATE-HASH"
    }

    text = inspect(user, limit: :infinity)
    for secret <- ["PRIVATE-PLAIN", "PRIVATE-CONFIRM", "PRIVATE-HASH"], do: refute(text =~ secret)
    assert text =~ "visible-reader"

    refute text =~ ~r/(?:<|, )(?:password|password_confirmation|hashed_password):/
  end

  test "inspecting a token redacts the hash and issuance nonce" do
    text =
      inspect(
        %Anime.Accounts.UserToken{
          context: :session,
          token: "PRIVATE-TOKEN",
          issue_nonce: "PRIVATE-NONCE"
        },
        limit: :infinity
      )

    refute text =~ "PRIVATE-TOKEN"
    refute text =~ "PRIVATE-NONCE"
    assert text =~ "context: :session"
    refute text =~ "token:"
    refute text =~ "issue_nonce:"
  end

  test "cleared identity fields yield required errors on an existing account" do
    user = %User{nick: "reader", email: "reader@example.test"}

    for empty <- [nil, "", "   "] do
      for {field, changeset} <- [
            {:nick, User.nick_changeset(user, %{nick: empty})},
            {:email, User.email_changeset(user, %{email: empty})},
            {:nick, User.admin_changeset(user, %{nick: empty})},
            {:email, User.admin_changeset(user, %{email: empty})}
          ] do
        refute changeset.valid?
        assert {"can't be blank", _} = changeset.errors[field]
      end
    end
  end

  test "registration changeset also accepts explicit clearing on populated data" do
    user = %User{nick: "reader", email: "reader@example.test"}

    for empty <- [nil, "", "   "] do
      changeset = User.registration_changeset(user, %{nick: empty, email: empty})
      refute changeset.valid?
      assert {"can't be blank", _} = changeset.errors[:nick]
      assert {"can't be blank", _} = changeset.errors[:email]
    end
  end

  test "nonempty identity values retain their normalization" do
    user = %User{nick: "reader", email: "reader@example.test"}

    assert Changeset.get_change(User.nick_changeset(user, %{nick: " Reader2 "}), :nick) ==
             "Reader2"

    assert Changeset.get_change(
             User.email_changeset(user, %{email: " NEW@EXAMPLE.TEST "}),
             :email
           ) ==
             "new@example.test"
  end
end
