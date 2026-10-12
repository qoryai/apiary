defmodule Apiary.Mail.PasswordTest do
  @moduledoc """
  The encryption of the SMTP password saved in Instance settings › Mail
  (`Apiary.Mail.Password`): the round trip under the key derived for `:mail`, and the
  associated data that binds it to its row, its field and where it is sent.
  """
  use ExUnit.Case, async: true

  alias Apiary.KeyDerivation
  alias Apiary.Mail.{Password, Settings}
  alias Apiary.Secrets.Cipher

  @password "correct horse battery staple"

  defp settings(fields \\ []) do
    struct!(
      %Settings{
        id: true,
        smtp_relay: "smtp.example.com",
        smtp_port: 587,
        smtp_tls: "always",
        smtp_username: "qory"
      },
      fields
    )
  end

  defp saved(settings, password) do
    {ciphertext, key_id} = Password.encrypt(settings, password)
    %{settings | smtp_password_ciphertext: ciphertext, mail_key_id: key_id}
  end

  test "decrypts what it encrypted, under the :mail key, with a fresh nonce each time" do
    settings = settings()
    {first, key_id} = Password.encrypt(settings, @password)
    {second, ^key_id} = Password.encrypt(settings, @password)

    assert {key_id, _key} = KeyDerivation.key(:mail)
    refute first == second
    # The nonce, the password and the tag: nothing of the password in clear.
    assert byte_size(first) == 12 + byte_size(@password) + 16
    refute first =~ @password

    assert Password.decrypt(%{settings | smtp_password_ciphertext: first, mail_key_id: key_id}) ==
             {:ok, @password}
  end

  test "no password is :none" do
    assert Password.decrypt(settings()) == :none
  end

  test "a change of the relay, the port, TLS or the username, made in the database, does not decrypt" do
    saved = saved(settings(), @password)

    for change <- [
          smtp_relay: "smtp.example.net",
          smtp_port: 25,
          smtp_tls: "never",
          smtp_username: "someone-else",
          smtp_username: nil
        ] do
      assert Password.decrypt(struct!(saved, [change])) == :error, inspect(change)
    end
  end

  test "is bound to its row and its field: the same key with other associated data does not decrypt" do
    settings = settings()
    {key_id, key} = KeyDerivation.key(:mail)

    for aad <- [
          "",
          Cipher.value_aad(Ecto.UUID.generate(), "sec_example", nil),
          String.replace(Password.aad(settings), "smtp_password", "smtp_username")
        ] do
      {nonce, ciphertext} = Cipher.encrypt(key, aad, @password)

      assert Password.decrypt(%{
               settings
               | smtp_password_ciphertext: nonce <> ciphertext,
                 mail_key_id: key_id
             }) == :error
    end
  end

  test "a key id the instance does not hold, or a changed ciphertext, does not decrypt" do
    saved = saved(settings(), @password)
    <<head::binary-size(20), byte, rest::binary>> = saved.smtp_password_ciphertext

    assert Password.decrypt(%{saved | mail_key_id: "0000000000000000"}) == :error

    assert Password.decrypt(%{
             saved
             | smtp_password_ciphertext: head <> <<Bitwise.bxor(byte, 1)>> <> rest
           }) == :error

    assert Password.decrypt(%{saved | smtp_password_ciphertext: binary_part(head, 0, 11)}) ==
             :error

    assert Password.decrypt(%{saved | mail_key_id: nil}) == :error
  end

  test "neither the password nor its ciphertext is in what inspect shows" do
    saved = %{saved(settings(), @password) | smtp_password: @password}
    shown = inspect(saved)

    refute shown =~ @password
    refute shown =~ inspect(saved.smtp_password_ciphertext)
    assert shown =~ "smtp.example.com"
  end
end
