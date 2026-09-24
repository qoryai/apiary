defmodule Apiary.Accounts.UserNotifier do
  @moduledoc """
  The mail sent to people. Each mail is written in the calling process's locale: a request
  or a LiveView has already set the body's (`ApiaryWeb.Lingo`), and a mail sent from a job
  about a hive wraps the call in `ApiaryWeb.Lingo.with_locale/2`.
  """
  use Gettext, backend: ApiaryWeb.Gettext
  import Swoosh.Email

  alias Apiary.Mailer
  alias Apiary.Accounts.User

  # Delivers the email using the application mailer. The body's paragraphs are whole,
  # translated sentences, set between the rules the tests and mail clients expect.
  defp deliver(recipient, subject, paragraphs) do
    body = """

    ==============================

    #{Enum.join(paragraphs, "\n\n")}

    ==============================
    """

    email =
      new()
      |> to(recipient)
      |> from(Mailer.from())
      |> subject(subject)
      |> text_body(body)

    with {:ok, _metadata} <- Mailer.deliver(email) do
      {:ok, email}
    end
  end

  @doc """
  Deliver instructions to update a user email.
  """
  def deliver_update_email_instructions(user, url) do
    deliver(user.email, gettext("Confirm your new email address for Qory Apiary"), [
      gettext("Hi %{email},", email: user.email),
      gettext(
        "You can change the email address of your Qory Apiary account by visiting the URL below:"
      ),
      url,
      gettext("If you did not ask for this change, ignore this email.")
    ])
  end

  @doc """
  Deliver instructions to log in with a magic link.
  """
  def deliver_login_instructions(user, url) do
    case user do
      %User{confirmed_at: nil} -> deliver_confirmation_instructions(user, url)
      _ -> deliver_magic_link_instructions(user, url)
    end
  end

  defp deliver_magic_link_instructions(user, url) do
    deliver(user.email, gettext("Your Qory Apiary log-in link"), [
      gettext("Hi %{email},", email: user.email),
      gettext("You can log in to Qory Apiary by visiting the URL below:"),
      url,
      gettext(
        "The link works once, for 15 minutes. If you did not ask for it, ignore this email."
      )
    ])
  end

  defp deliver_confirmation_instructions(user, url) do
    deliver(user.email, gettext("Confirm your Qory Apiary account"), [
      gettext("Hi %{email},", email: user.email),
      gettext("You can confirm your Qory Apiary account by visiting the URL below:"),
      url,
      gettext("If you did not create a Qory Apiary account, ignore this email.")
    ])
  end

  @doc """
  Deliver an invitation to join an organisation.
  """
  def deliver_invitation(email, inviter, organisation, url) do
    deliver(
      email,
      gettext("You are invited to %{organisation} on Qory Apiary",
        organisation: organisation.name
      ),
      [
        gettext("Hi %{email},", email: email),
        gettext(
          "%{inviter} has invited you to join %{organisation} on Qory Apiary. You can accept the invitation by visiting the URL below:",
          inviter: inviter.email,
          organisation: organisation.name
        ),
        url,
        gettext(
          "The invitation is valid for seven days. If you were not expecting it, ignore this email."
        )
      ]
    )
  end
end
