defmodule Substrate.Lisp.Error do
  @moduledoc """
  A fault raised *inside* the L2 sandbox — a malformed program, an unbound
  symbol, a bad capability call. It is caught at the harness boundary and
  surfaced to the agent as an observation, never crashing L0 (DESIGN: "can't
  break itself" — OTP supervision; here, a clean catch).
  """
  defexception [:message]
end
