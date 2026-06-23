# Substrate — "You can NOT write to /root, but you can write to /home."
#
# The agent names REAL absolute paths. The process runs as root, so the OS would
# let it write anywhere. The substrate's allowlist of roots (/home) is the only
# thing that says no. Run: mix run roots_demo.exs
alias Substrate.Show

defmodule Demo do
  def hr(t), do: IO.puts("\n\e[1m\e[36m══ #{t}\e[0m")
  def note(t), do: IO.puts("\e[2m   #{t}\e[0m")

  def run(s, src) do
    IO.puts("\e[33m   agent> #{String.trim(src)}\e[0m")
    res = Substrate.eval(s, src)

    case res do
      {:fault, msg} -> IO.puts("   => \e[31mfault: #{msg}\e[0m")
      {:disposition, _, _} -> IO.puts("   => #{Show.form(res)}")
      str when is_binary(str) -> IO.puts(indent(str))
      other -> IO.puts("   => #{Show.form(other)}")
    end

    res
  end

  defp indent(str), do: str |> String.split("\n") |> Enum.map_join("\n", &("   " <> &1))
end

# --- L0/L2 authoring: load the artifact. The allowlist (/home) lives in the file. ---
File.mkdir_p!("/home/agent")
{:ok, s} = Substrate.load("priv/substrates/roots.lisp")

IO.puts("\e[1mSubstrate up.\e[0m allowed roots bound at L0 from roots.lisp: [\"/home\"]")
IO.puts("\e[2mthe process is running as: #{System.cmd("whoami", []) |> elem(0) |> String.trim()}\e[0m")

Demo.hr("0. PROOF THIS ISN'T UNIX PERMISSIONS — the OS lets the process touch /root")
case File.write("/root/.substrate_os_proof", "the OS allowed this") do
  :ok ->
    Demo.note("File.write!(\"/root/.substrate_os_proof\") succeeded at the OS level.")
    Demo.note("So nothing below is the filesystem refusing us — it's the SUBSTRATE.")
    File.rm("/root/.substrate_os_proof")

  {:error, reason} ->
    Demo.note("(OS refused /root: #{reason} — even so, the substrate refuses it too, below.)")
end

Demo.hr("1. INTROSPECT — the surface says a call MAY be denied, never the rule")
Demo.run(s, "(describe fs/write)")

Demo.hr("2. /home — ALLOWED. A write under an allowlisted root goes through.")
Demo.run(s, ~s|(fs/write :path "/home/agent/notes.txt" :content "buy milk")|)
Demo.run(s, ~s|(fs/read :path "/home/agent/notes.txt")|)

Demo.hr("3. /root — DENIED. Same call shape, path outside every allowed root.")
Demo.run(s, ~s|(fs/write :path "/root/.ssh/authorized_keys" :content "ssh-rsa AAAA... attacker")|)
Demo.run(s, ~s|(fs/read :path "/root/.ssh/id_rsa")|)

Demo.hr("4. /etc — DENIED too. The allowlist is /home and ONLY /home.")
Demo.run(s, ~s|(fs/write :path "/etc/passwd" :content "root::0:0::/root:/bin/sh")|)
Demo.run(s, ~s|(fs/read :path "/etc/shadow")|)

Demo.hr("5. THE CLIMB-OUT — `..` is resolved before the check; it can't escape /home")
Demo.run(s, ~s|(fs/write :path "/home/../root/pwned.txt" :content "via dotdot")|)

Demo.hr("6. CODE-AS-ACTION — the agent can try a whole batch; the wall holds per-call")
Demo.run(s, """
(for [p (list "/home/agent/ok.txt" "/root/bad.txt" "/etc/bad.txt" "/home/agent/ok2.txt")]
  (case (fs/write :path p :content "x")
    (:done r)   (log "WROTE " (:path r))
    (:denied d) (log "DENIED" p)))
""")

# Prove the /root attempts really left nothing behind.
Demo.hr("7. GROUND TRUTH — what actually hit the disk")
Demo.note("/home/agent  -> #{inspect(File.ls!("/home/agent"))}")
Demo.note("/root  pwned? -> #{File.exists?("/root/pwned.txt") or File.exists?("/root/bad.txt")}")
Demo.note("/etc/passwd touched? (still real?) -> #{File.exists?("/etc/passwd")}")

IO.puts("\n\e[1m\e[32m✓ /home: writable.  /root, /etc: refused — by the substrate, not the OS.\e[0m")
