defmodule Anime.SMTPTLSTest do
  use ExUnit.Case, async: true
  @moduletag :capture_log

  setup_all do
    {dir, 0} =
      System.cmd("mktemp", ["-d", Path.join(System.tmp_dir!(), "anime-smtp-tls.XXXXXXXX")])

    dir = String.trim(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    ca = Path.join(dir, "ca.pem")
    ca_key = Path.join(dir, "ca.key")

    {_, 0} =
      System.cmd(
        "openssl",
        [
          "req",
          "-x509",
          "-newkey",
          "rsa:2048",
          "-nodes",
          "-days",
          "1",
          "-subj",
          "/CN=Local SMTP Test CA",
          "-addext",
          "basicConstraints=critical,CA:TRUE",
          "-keyout",
          ca_key,
          "-out",
          ca
        ], stderr_to_stdout: true)

    [{:Certificate, ca_der, _}] = ca |> File.read!() |> :public_key.pem_decode()

    certs =
      for name <- ["localhost", "wrong.test"], into: %{} do
        cert = Path.join(dir, name <> ".pem")
        key = Path.join(dir, name <> ".key")
        csr = Path.join(dir, name <> ".csr")

        {_, 0} =
          System.cmd(
            "openssl",
            [
              "req",
              "-new",
              "-newkey",
              "rsa:2048",
              "-nodes",
              "-subj",
              "/CN=" <> name,
              "-addext",
              "subjectAltName=DNS:" <> name,
              "-addext",
              "basicConstraints=critical,CA:FALSE",
              "-addext",
              "extendedKeyUsage=serverAuth",
              "-keyout",
              key,
              "-out",
              csr
            ],
            stderr_to_stdout: true
          )

        {_, 0} =
          System.cmd(
            "openssl",
            [
              "x509",
              "-req",
              "-in",
              csr,
              "-CA",
              ca,
              "-CAkey",
              ca_key,
              "-CAcreateserial",
              "-days",
              "1",
              "-copy_extensions",
              "copy",
              "-out",
              cert
            ], stderr_to_stdout: true)

        {name, %{cert: cert, key: key, der: ca_der}}
      end

    %{certs: certs}
  end

  test "trusted matching certificate carries authenticated SMTP and envelope over TLS", %{
    certs: certs
  } do
    {result, transcript} = exchange(certs["localhost"], true)
    assert {:delivered, from, recipient, body} = transcript
    assert {:ok, _} = result
    assert from == "MAIL FROM:<bounce@example.test>\r\n"
    assert recipient == "RCPT TO:<recipient@example.test>\r\n"
    assert body =~ "TLS test message"
  end

  test "untrusted certificate is refused during STARTTLS", %{certs: certs} do
    assert {{:error, _}, {:tls_error, _}} = exchange(certs["localhost"], false)
  end

  test "trusted certificate with wrong hostname is refused during STARTTLS", %{certs: certs} do
    assert {{:error, _}, {:tls_error, _}} = exchange(certs["wrong.test"], true)
  end

  defp exchange(cert, trust?) do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, packet: :line, ip: {127, 0, 0, 1}])

    on_exit(fn -> :gen_tcp.close(listener) end)
    {:ok, {_, port}} = :inet.sockname(listener)
    server = Task.async(fn -> serve(listener, cert) end)

    config =
      Anime.MailConfig.load!(
        %{
          "SMTP_HOST" => "localhost",
          "SMTP_PORT" => to_string(port),
          "SMTP_USERNAME" => "synthetic-user",
          "SMTP_PASSWORD" => "synthetic-password",
          "MAIL_RETURN_PATH" => "bounce@example.test"
        },
        "staging",
        "example.test"
      )

    opts =
      if trust?,
        do: Keyword.update!(config.options, :tls_options, &Keyword.put(&1, :cacerts, [cert.der])),
        else: config.options

    email =
      Swoosh.Email.new()
      |> Swoosh.Email.from("sender@example.test")
      |> Swoosh.Email.to("recipient@example.test")
      |> Swoosh.Email.subject("TLS test")
      |> Swoosh.Email.text_body("TLS test message")
      |> Swoosh.Email.header("Sender", config.return_path)

    result = Swoosh.Adapters.SMTP.deliver(email, opts)
    {result, Task.await(server, 10_000)}
  end

  defp serve(listener, cert) do
    {:ok, socket} = :gen_tcp.accept(listener, 5000)

    try do
      :ok = :gen_tcp.send(socket, "220 localhost ESMTP\r\n")
      {:ok, "EHLO " <> _} = :gen_tcp.recv(socket, 0, 5000)
      :ok = :gen_tcp.send(socket, "250-localhost\r\n250 STARTTLS\r\n")
      {:ok, "STARTTLS\r\n"} = :gen_tcp.recv(socket, 0, 5000)
      :ok = :gen_tcp.send(socket, "220 Ready for TLS\r\n")

      case :ssl.handshake(
             socket,
             [
               certfile: String.to_charlist(cert.cert),
               keyfile: String.to_charlist(cert.key),
               active: false,
               packet: :line,
               mode: :binary
             ],
             5000
           ) do
        {:ok, tls} ->
          try do
            receive_mail(tls)
          after
            :ssl.close(tls)
          end

        {:error, reason} ->
          {:tls_error, reason}
      end
    after
      :gen_tcp.close(socket)
    end
  end

  defp receive_mail(socket) do
    {:ok, "EHLO " <> _} = :ssl.recv(socket, 0, 5000)
    :ok = :ssl.send(socket, "250-localhost\r\n250 AUTH PLAIN\r\n")
    {:ok, "AUTH PLAIN " <> auth} = :ssl.recv(socket, 0, 5000)

    assert Base.decode64!(String.trim(auth)) ==
             <<0>> <> "synthetic-user" <> <<0>> <> "synthetic-password"

    :ok = :ssl.send(socket, "235 Authenticated\r\n")
    {:ok, from} = :ssl.recv(socket, 0, 5000)
    :ok = :ssl.send(socket, "250 OK\r\n")
    {:ok, recipient} = :ssl.recv(socket, 0, 5000)
    :ok = :ssl.send(socket, "250 OK\r\n")
    {:ok, "DATA\r\n"} = :ssl.recv(socket, 0, 5000)
    :ok = :ssl.send(socket, "354 End with dot\r\n")
    body = receive_body(socket, [])
    :ok = :ssl.send(socket, "250 queued-test\r\n")

    case :ssl.recv(socket, 0, 2000) do
      {:ok, "QUIT\r\n"} -> :ssl.send(socket, "221 bye\r\n")
      {:error, :closed} -> :ok
    end

    {:delivered, from, recipient, body}
  end

  defp receive_body(socket, lines) do
    {:ok, line} = :ssl.recv(socket, 0, 5000)

    if line == ".\r\n",
      do: lines |> Enum.reverse() |> IO.iodata_to_binary(),
      else: receive_body(socket, [line | lines])
  end
end
