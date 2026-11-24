// Tech Toolkit - lanceur de la cle USB
// Place a la racine de la partition TOOLS, a cote de toolkit.ps1 et tools.json.
// Lance toolkit.ps1 en administrateur (une seule invite UAC), en mode cle USB.
// Volontairement minimal : le code de l'outil reste dans toolkit.ps1, lisible et mis a jour par "Creer ma cle".
using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Windows.Forms;

[assembly: AssemblyTitle("Tech Toolkit")]
[assembly: AssemblyProduct("Tech Toolkit")]
[assembly: AssemblyDescription("Lanceur de Tech Toolkit (cle USB technicien)")]
[assembly: AssemblyCompany("Nagory-ST")]
[assembly: AssemblyVersion("1.0.0.0")]
[assembly: AssemblyFileVersion("1.0.0.0")]

static class Program
{
    [STAThread]
    static int Main()
    {
        string dir = AppDomain.CurrentDomain.BaseDirectory;          // ex. "E:\" (avec antislash final)
        string script = Path.Combine(dir, "toolkit.ps1");
        if (!File.Exists(script))
        {
            MessageBox.Show("toolkit.ps1 est introuvable à côté de TechToolkit.exe :\n" + dir,
                            "Tech Toolkit", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }

        string powershell = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System),
                                         @"WindowsPowerShell\v1.0\powershell.exe");
        // Lecture explicite en UTF-8 (accents) ; TK_ROOT indique le mode cle USB a toolkit.ps1
        string command = "$env:TK_ROOT='" + dir.Replace("'", "''") + "'; " +
                         "iex ([IO.File]::ReadAllText('" + script.Replace("'", "''") + "',[Text.Encoding]::UTF8))";

        ProcessStartInfo psi = new ProcessStartInfo(powershell,
            "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Minimized -Command \"" + command + "\"");
        psi.UseShellExecute = true;
        psi.Verb = "runas";            // elevation directe
        psi.WorkingDirectory = dir;
        try
        {
            Process.Start(psi);
        }
        catch (System.ComponentModel.Win32Exception)
        {
            // Invite UAC refusee
            return 2;
        }
        return 0;
    }
}
