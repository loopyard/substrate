# Substrate — the web substrate: HTTP(S) + locked filesystem, end to end.
# An agent surfs a few allowlisted sites, downloads files, and saves them to a
# few allowlisted directories — and CANNOT do anything else. Run: mix run web_demo.exs
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

# --- L0/L2 authoring: mount TWO substrates on one surface, bind the allowlists ---
root = Path.join(System.tmp_dir!(), "web_demo_jail")
File.rm_rf!(root)
for d <- ~w(downloads cache), do: File.mkdir_p!(Path.join(root, d))

{:ok, s} = Substrate.start_link(name: nil)
fs = "priv/manifests/fs_locked.lisp" |> File.read!() |> Substrate.read_manifest()
http = "priv/manifests/http.lisp" |> File.read!() |> Substrate.read_manifest()

# DENY-ALL by default; we punch two small holes, both named only here at L0:
:ok = Substrate.mount(s, fs, credentials: %{fs_root: root, fs_allow: ["downloads", "cache"]})
:ok = Substrate.mount(s, http, credentials: %{http_allow: ["example.com", "raw.githubusercontent.com"]})

IO.puts("\e[1mWeb substrate up.\e[0m  two substrates, one surface.")
Demo.note("jail root (agent can't name it): #{root}")
Demo.note("write allowlist: downloads/ cache/    host allowlist: example.com raw.githubusercontent.com")

Demo.hr("1. THE SURFACE — two namespaces, fs + http, on one wall")
Demo.run(s, "(describe)")

Demo.hr("2. SURF — GET an allowlisted host (the only network the agent has)")
Demo.run(s, ~s"""
(let [r (http/get :url "https://example.com")]
  (case r
    (:done d)   (str "fetched " (:status d) ", " (:bytes d) " bytes")
    (:denied e) "denied"))
""")

Demo.hr("3. DOWNLOAD → DISK — one program: fetch, then save to an allowed dir")
Demo.note("http/get and fs/write compose in a single emission — a computer, not two tool-calls")
Demo.run(s, ~s"""
(let [r (http/get :url "https://raw.githubusercontent.com/torvalds/linux/master/README")]
  (case r
    (:done d)   (fs/write :path "downloads/linux-README" :content (:body d))
    (:denied e) (log "download denied")))
""")
saved = Path.join(root, "downloads/linux-README")
Demo.note("on disk: #{File.exists?(saved)}, #{File.stat!(saved).size} bytes at downloads/linux-README")

Demo.hr("4. BREAK IT — host NOT on the allowlist  (deny-all by default)")
Demo.run(s, ~s|(http/get :url "https://api.github.com/user")|)
Demo.run(s, ~s|(http/get :url "http://169.254.169.254/latest/meta-data/")|)
Demo.note("the cloud metadata SSRF target above is just another non-allowlisted host: denied")

Demo.hr("5. BREAK IT — write to a dir NOT on the allowlist  (deny-all by default)")
Demo.run(s, ~s|(fs/write :path "secrets/stolen.txt" :content "x")|)
Demo.run(s, ~s|(fs/write :path "id_rsa" :content "x")|)

Demo.hr("6. BREAK IT — escape the jail entirely")
Demo.run(s, ~s|(fs/write :path "../../etc/cron.d/pwn" :content "x")|)
Demo.run(s, ~s|(fs/read :path "../../../etc/passwd")|)

Demo.hr("7. BREAK IT — the combined attack: download from an allowed host, exfil to a forbidden path")
Demo.note("the GET is allowed; the WRITE is where it dies — the two clamps compose")
Demo.run(s, ~s"""
(let [r (http/get :url "https://example.com")]
  (case r
    (:done d)   (fs/write :path "../../tmp/exfil" :content (:body d))
    (:denied e) (log "blocked at fetch")))
""")
Demo.note("exfil on disk? #{File.exists?(Path.join(root, "../../tmp/exfil"))}  (false — write-denied caught it)")

Demo.hr("8. BREAK IT — the wall: there is no expression that reaches the network or the creds directly")
Demo.run(s, ~s|(http-get "http://evil.example/x")|)
Demo.run(s, ~s|(System/cmd "curl" "evil.example")|)

IO.puts("\n\e[1m\e[32m✓ surf + download + save — bounded to a few hosts and a few dirs, by construction.\e[0m")
