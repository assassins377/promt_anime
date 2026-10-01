defmodule Anime.SMTPTransportTest do
  use ExUnit.Case, async: true
  @moduletag :capture_log

  test "required STARTTLS refuses a real plaintext relay before authentication or message data" do
    refuses_relay("always", "250-localhost\r\n250 AUTH PLAIN LOGIN\r\n")
  end

  test "required authentication refuses a real relay that offers no AUTH" do
    refuses_relay("never", "250 localhost\r\n")
  end

  defp refuses_relay(tls, extensions) do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, packet: :line, ip: {127, 0, 0, 1}])

    on_exit(fn -> :gen_tcp.close(listener) end)
    {:ok, {_, port}} = :inet.sockname(listener)

    server =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener, 5000)

        try do
          :ok = :gen_tcp.send(socket, "220 localhost ESMTP test\r\n")
          {:ok, greeting} = :gen_tcp.recv(socket, 0, 5000)
          :ok = :gen_tcp.send(socket, extensions)
          next = :gen_tcp.recv(socket, 0, 2000)
          if match?({:ok, "QUIT" <> _}, next), do: :gen_tcp.send(socket, "221 bye\r\n")
          {greeting, next}
        after
          :gen_tcp.close(socket)
        end
      end)

    config =
      Anime.MailConfig.load!(
        %{
          "SMTP_HOST" => "127.0.0.1",
          "SMTP_PORT" => Integer.to_string(port),
          "SMTP_USERNAME" => "synthetic-user",
          "SMTP_PASSWORD" => "synthetic-password",
          "SMTP_TLS" => tls,
          "MAIL_RETURN_PATH" => "bounce@example.test"
        },
        "staging",
        "example.test"
      )

    email =
      Swoosh.Email.new()
      |> Swoosh.Email.from("sender@example.test")
      |> Swoosh.Email.to("recipient@example.test")
      |> Swoosh.Email.subject("test only")
      |> Swoosh.Email.text_body("not transmitted")

    assert {:error, _} = Swoosh.Adapters.SMTP.deliver(email, config.options)
    {greeting, next} = Task.await(server, 5000)
    assert String.starts_with?(greeting, "EHLO ")
    assert next in [{:error, :closed}, {:ok, "QUIT\r\n"}]
  end
end
