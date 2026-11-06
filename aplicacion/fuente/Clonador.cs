// Clonador de voz — ventana nativa de la aplicacion.
//
// Arranca el servidor local (con lanzador.ps1 -SoloServidor) y muestra la
// interfaz dentro de su propia ventana, con el icono del microfono y una
// identidad propia en la barra de tareas (AppUserModelID), para que al
// anclarla conserve el icono y no aparezca como "Microsoft Edge".
//
// Se compila con csc (C# 5) y se apoya en el runtime WebView2 que trae Windows.

using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.WinForms;

namespace ClonadorVoz
{
    internal static class Programa
    {
        internal const string Aumid = "ClonadorVoz.Local";
        internal const string Titulo = "Clonador de voz";

        [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
        private static extern int SetCurrentProcessExplicitAppUserModelID(string appId);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern IntPtr FindWindow(string clase, string titulo);

        [DllImport("user32.dll")]
        private static extern bool SetForegroundWindow(IntPtr ventana);

        [DllImport("user32.dll")]
        private static extern bool ShowWindow(IntPtr ventana, int comando);

        [DllImport("user32.dll")]
        private static extern uint GetDpiForSystem();

        [STAThread]
        private static int Main()
        {
            string raiz = AppDomain.CurrentDomain.BaseDirectory.EndsWith("\\")
                ? AppDomain.CurrentDomain.BaseDirectory
                : AppDomain.CurrentDomain.BaseDirectory + "\\";

            bool nueva;
            Mutex mutex = new Mutex(true, @"Local\ClonadorVoz.Local.Single", out nueva);
            if (!nueva)
            {
                TraerAlFrente();
                return 0;
            }

            try { SetCurrentProcessExplicitAppUserModelID(Aumid); } catch { }
            RegistrarIdentidad(raiz);

            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            Application.Run(new Ventana(raiz));
            GC.KeepAlive(mutex);
            return 0;
        }

        internal static float EscalaDpi()
        {
            try
            {
                uint dpi = GetDpiForSystem();
                if (dpi > 0) return dpi / 96f;
            }
            catch { }
            try
            {
                using (Graphics g = Graphics.FromHwnd(IntPtr.Zero)) return g.DpiX / 96f;
            }
            catch { }
            return 1f;
        }

        private static void TraerAlFrente()
        {
            try
            {
                IntPtr h = FindWindow(null, Titulo);
                if (h != IntPtr.Zero)
                {
                    ShowWindow(h, 9);   // SW_RESTORE
                    SetForegroundWindow(h);
                }
            }
            catch { }
        }

        // Hace que Windows conozca la identidad de la app: nombre e icono para
        // la barra de tareas y para el anclaje.
        private static void RegistrarIdentidad(string raiz)
        {
            try
            {
                string exe = Path.Combine(raiz, "Clonador de voz.exe");
                string ico = Path.Combine(raiz, "icono.ico");
                using (Microsoft.Win32.RegistryKey clave =
                    Microsoft.Win32.Registry.CurrentUser.CreateSubKey(@"Software\Classes\AppUserModelId\" + Aumid))
                {
                    if (clave == null) return;
                    clave.SetValue("DisplayName", Titulo);
                    if (File.Exists(ico)) clave.SetValue("IconUri", ico);
                    if (File.Exists(exe)) clave.SetValue("RelaunchCommand", "\"" + exe + "\"");
                }
            }
            catch { }
        }

        // Deja el servidor listo y devuelve el puerto, o 0 si fallo.
        internal static int AsegurarServidor(string raiz)
        {
            string script = Path.Combine(raiz, "lanzador.ps1");
            string sistema = Environment.GetFolderPath(Environment.SpecialFolder.System);
            string ps = Path.Combine(sistema, @"WindowsPowerShell\v1.0\powershell.exe");
            if (!File.Exists(ps)) ps = "powershell.exe";

            string carpetaDatos = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "ClonadorVoz");
            string archivoPuerto = Path.Combine(carpetaDatos, "puerto.txt");

            try
            {
                Directory.CreateDirectory(carpetaDatos);
                File.Delete(archivoPuerto);
            }
            catch { }

            try
            {
                ProcessStartInfo si = new ProcessStartInfo();
                si.FileName = ps;
                si.Arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File \""
                    + script + "\" -SoloServidor";
                si.UseShellExecute = false;
                si.CreateNoWindow = true;
                si.RedirectStandardOutput = true;
                si.RedirectStandardError = true;
                si.WorkingDirectory = raiz;

                using (Process p = Process.Start(si))
                {
                    // Ojo: no se puede esperar a que la tuberia se cierre, porque
                    // pythonw hereda la salida del lanzador y la mantendria abierta.
                    // Se lee de forma asincrona y el puerto se toma de puerto.txt.
                    StringBuilder salida = new StringBuilder();
                    StringBuilder errores = new StringBuilder();

                    p.OutputDataReceived += delegate(object emisor, DataReceivedEventArgs e)
                    {
                        if (e.Data != null) { lock (salida) salida.AppendLine(e.Data); }
                    };
                    p.ErrorDataReceived += delegate(object emisor, DataReceivedEventArgs e)
                    {
                        if (e.Data != null) { lock (errores) errores.AppendLine(e.Data); }
                    };
                    p.BeginOutputReadLine();
                    p.BeginErrorReadLine();

                    // El lanzador espera hasta 3 minutos al servidor; aqui se le
                    // deja margen para que no lo cortemos antes de tiempo.
                    if (!p.WaitForExit(200000))
                    {
                        try { p.Kill(); } catch { }
                        Registrar("el lanzador no termino en 200 s");
                        return 0;
                    }

                    int puerto = 0;
                    for (int intento = 0; intento < 20 && puerto <= 0; intento++)
                    {
                        try
                        {
                            if (File.Exists(archivoPuerto))
                            {
                                int n;
                                if (int.TryParse(File.ReadAllText(archivoPuerto).Trim(), out n) && n > 0) puerto = n;
                            }
                        }
                        catch { }
                        if (puerto <= 0) Thread.Sleep(100);
                    }
                    if (puerto > 0)
                    {
                        Registrar("servidor listo en el puerto " + puerto);
                        return puerto;
                    }

                    string textoSalida;
                    lock (salida) { textoSalida = salida.ToString(); }
                    string textoErrores;
                    lock (errores) { textoErrores = errores.ToString(); }

                    foreach (string linea in textoSalida.Split(new char[] { '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries))
                    {
                        string limpia = linea.Trim();
                        if (limpia.StartsWith("PUERTO="))
                        {
                            int n;
                            if (int.TryParse(limpia.Substring(7).Trim(), out n) && n > 0)
                            {
                                Registrar("servidor listo en el puerto " + n);
                                return n;
                            }
                        }
                        if (limpia.StartsWith("ERROR=")) Registrar("lanzador: " + limpia.Substring(6));
                    }

                    if (!string.IsNullOrEmpty(textoErrores)) Registrar("stderr: " + textoErrores.Trim());
                }
            }
            catch (Exception ex)
            {
                Registrar("excepcion: " + ex.Message);
            }
            return 0;
        }

        internal static void Registrar(string texto)
        {
            try
            {
                string carpeta = Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                    @"ClonadorVoz\logs");
                Directory.CreateDirectory(carpeta);
                File.AppendAllText(Path.Combine(carpeta, "ventana.log"),
                    DateTime.Now.ToString("s") + "  " + texto + Environment.NewLine);
            }
            catch { }
        }
    }

    internal sealed class Ventana : Form
    {
        private readonly WebView2 web;
        private readonly Label carga;
        private readonly string raiz;
        private bool respaldoLanzado;

        internal Ventana(string raiz)
        {
            this.raiz = raiz;

            AutoScaleMode = AutoScaleMode.None;
            Text = Programa.Titulo;
            StartPosition = FormStartPosition.CenterScreen;
            BackColor = Color.FromArgb(18, 18, 22);
            MinimumSize = new Size(900, 620);
            try { Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath); } catch { }
            CalcularTamano();

            web = new WebView2();
            web.Dock = DockStyle.Fill;
            Controls.Add(web);

            carga = new Label();
            carga.Dock = DockStyle.Fill;
            carga.TextAlign = ContentAlignment.MiddleCenter;
            carga.Text = "Arrancando el clonador de voz...";
            carga.ForeColor = Color.Gainsboro;
            carga.BackColor = Color.FromArgb(18, 18, 22);
            carga.Font = new Font("Segoe UI", 17f * Programa.EscalaDpi(), FontStyle.Regular, GraphicsUnit.Pixel);
            Controls.Add(carga);
            carga.BringToFront();

            Load += AlCargar;
        }

        private void CalcularTamano()
        {
            float escala = Programa.EscalaDpi();
            Rectangle area = Screen.PrimaryScreen.WorkingArea;

            int ancho = (int)Math.Round(1400 * escala);
            int alto = (int)Math.Round(940 * escala);
            int topeAncho = (int)Math.Round(area.Width * 0.92);
            int topeAlto = (int)Math.Round(area.Height * 0.92);

            if (ancho > topeAncho) ancho = topeAncho;
            if (alto > topeAlto) alto = topeAlto;
            if (ancho < 900) ancho = Math.Min(900, area.Width);
            if (alto < 620) alto = Math.Min(620, area.Height);

            ClientSize = new Size(ancho, alto);
        }

        private async void AlCargar(object remitente, EventArgs e)
        {
            try
            {
                int puerto = await Task.Run(() => Programa.AsegurarServidor(raiz));
                if (puerto <= 0)
                {
                    carga.Text = "No se pudo arrancar el servidor."
                        + Environment.NewLine + Environment.NewLine
                        + "Revisa el registro en:" + Environment.NewLine
                        + @"%LOCALAPPDATA%\ClonadorVoz\logs";
                    Programa.Registrar("no se pudo arrancar el servidor");
                    return;
                }

                string perfil = Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                    @"ClonadorVoz\webview2");
                Directory.CreateDirectory(perfil);

                CoreWebView2Environment entorno = await CoreWebView2Environment.CreateAsync(null, perfil, null);
                await web.EnsureCoreWebView2Async(entorno);

                CoreWebView2 nucleo = web.CoreWebView2;
                nucleo.Settings.IsStatusBarEnabled = false;
                nucleo.Settings.AreDevToolsEnabled = false;
                nucleo.Settings.IsZoomControlEnabled = true;

                nucleo.PermissionRequested += AlPedirPermiso;
                nucleo.NewWindowRequested += AlaNuevaVentana;
                nucleo.NavigationCompleted += AlNavegar;
                nucleo.ProcessFailed += AlFallarProceso;

                carga.Text = "Cargando la interfaz...";
                web.Source = new Uri("http://127.0.0.1:" + puerto + "/");
            }
            catch (Exception ex)
            {
                Programa.Registrar("WebView2: " + ex.ToString());
                Respaldo(ex);
            }
        }

        // El microfono (grabar) se permite solo para la propia app local.
        private void AlPedirPermiso(object remitente, CoreWebView2PermissionRequestedEventArgs e)
        {
            if (e.Uri != null && e.Uri.StartsWith("http://127.0.0.1:", StringComparison.OrdinalIgnoreCase))
            {
                e.State = CoreWebView2PermissionState.Allow;
            }
            else
            {
                e.State = CoreWebView2PermissionState.Deny;
            }
        }

        // Los enlaces externos se abren en el navegador del sistema.
        private void AlaNuevaVentana(object remitente, CoreWebView2NewWindowRequestedEventArgs e)
        {
            e.Handled = true;
            try { Process.Start(e.Uri); } catch { }
        }

        private void AlNavegar(object remitente, CoreWebView2NavigationCompletedEventArgs e)
        {
            if (e.IsSuccess)
            {
                carga.Visible = false;
            }
            else
            {
                carga.Visible = true;
                carga.Text = "No se pudo cargar la interfaz."
                    + Environment.NewLine + Environment.NewLine
                    + "Revisa el registro en:" + Environment.NewLine
                    + @"%LOCALAPPDATA%\ClonadorVoz\logs";
            }
        }

        private void AlFallarProceso(object remitente, CoreWebView2ProcessFailedEventArgs e)
        {
            Programa.Registrar("fallo de proceso WebView2: " + e.ProcessFailedKind);
        }

        // Si WebView2 no esta disponible, se abre como antes (Edge en modo app).
        private void Respaldo(Exception ex)
        {
            if (respaldoLanzado) return;
            respaldoLanzado = true;

            try
            {
                MessageBox.Show(
                    "No se pudo abrir la ventana integrada." + Environment.NewLine + Environment.NewLine
                    + ex.Message + Environment.NewLine + Environment.NewLine
                    + "Se abrirá en el navegador, como antes.",
                    Programa.Titulo, MessageBoxButtons.OK, MessageBoxIcon.Warning);
            }
            catch { }

            try
            {
                string vbs = Path.Combine(raiz, "Lanzar clonador de voz.vbs");
                if (File.Exists(vbs))
                {
                    ProcessStartInfo si = new ProcessStartInfo();
                    si.FileName = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "wscript.exe");
                    si.Arguments = "\"" + vbs + "\"";
                    si.UseShellExecute = true;
                    si.WorkingDirectory = raiz;
                    Process.Start(si);
                }
            }
            catch { }

            Close();
        }
    }
}
