# Control de la app de Windows vía UI Automation (API estándar de accesibilidad).
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
$uiaRefs = @(
    [System.Windows.Automation.AutomationElement].Assembly.Location,
    [System.Windows.Automation.ControlType].Assembly.Location,
    [System.Windows.Automation.InvokePattern].Assembly.Location
)
Add-Type -ReferencedAssemblies $uiaRefs -TypeDefinition @"
using System;
using System.Windows.Automation;

public class VideoDownloaderUiA {

    public static AutomationElement FindWindow(string title) {
        var root = AutomationElement.RootElement;
        var cond = new PropertyCondition(AutomationElement.NameProperty, title);
        return root.FindFirst(TreeScope.Children, cond);
    }

    public static AutomationElement FindByName(AutomationElement scope, string name) {
        if (scope == null) return null;
        var cond = new PropertyCondition(AutomationElement.NameProperty, name);
        return scope.FindFirst(TreeScope.Descendants, cond);
    }

    public static AutomationElement FindButtonByText(AutomationElement scope, string text) {
        if (scope == null) return null;
        var c1 = new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.Button);
        var all = scope.FindAll(TreeScope.Descendants, c1);
        foreach (AutomationElement e in all) {
            var n = e.Current.Name ?? "";
            if (n.IndexOf(text, StringComparison.OrdinalIgnoreCase) >= 0) return e;
        }
        return null;
    }

    public static AutomationElement FindEdit(AutomationElement scope) {
        if (scope == null) return null;
        var c1 = new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.Edit);
        var all = scope.FindAll(TreeScope.Descendants, c1);
        foreach (AutomationElement e in all) return e;
        return null;
    }

    public static bool Invoke(AutomationElement el) {
        if (el == null) return false;
        object p;
        if (el.TryGetCurrentPattern(InvokePattern.Pattern, out p)) {
            ((InvokePattern)p).Invoke();
            return true;
        }
        if (el.TryGetCurrentPattern(TogglePattern.Pattern, out p)) {
            ((TogglePattern)p).Toggle();
            return true;
        }
        if (el.TryGetCurrentPattern(SelectionItemPattern.Pattern, out p)) {
            ((SelectionItemPattern)p).Select();
            return true;
        }
        return false;
    }

    public static bool SetValue(AutomationElement el, string value) {
        if (el == null) return false;
        try { el.SetFocus(); } catch { }
        System.Threading.Thread.Sleep(150);
        object p;
        if (el.TryGetCurrentPattern(ValuePattern.Pattern, out p)) {
            try {
                var vp = (ValuePattern)p;
                if (vp.Current.IsReadOnly) return false;
                vp.SetValue(value);
                return true;
            } catch { return false; }
        }
        return false;
    }

    // Los botones con degradado exponen el texto en un hijo; el nodo
    // Button a menudo viene sin nombre. Busca el Button que CONTIENE texto.
    public static AutomationElement FindButtonContaining(AutomationElement scope, string text) {
        if (scope == null) return null;
        var c1 = new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.Button);
        foreach (AutomationElement e in scope.FindAll(TreeScope.Descendants, c1)) {
            var n = e.Current.Name ?? "";
            if (n.IndexOf(text, StringComparison.OrdinalIgnoreCase) >= 0) return e;
            foreach (AutomationElement k in e.FindAll(TreeScope.Descendants, Condition.TrueCondition)) {
                var kn = k.Current.Name ?? "";
                if (kn.IndexOf(text, StringComparison.OrdinalIgnoreCase) >= 0) return e;
            }
        }
        return null;
    }

    // Sube por el árbol desde un nodo de texto hasta encontrar un Button
    // ancestro (los InkWell de degradado quedan como nodos sin nombre).
    public static AutomationElement FindAncestorButton(AutomationElement scope, string text) {
        if (scope == null) return null;
        var cond = new PropertyCondition(AutomationElement.NameProperty, text);
        var t = scope.FindFirst(TreeScope.Descendants, cond);
        if (t == null) return null;
        var walker = TreeWalker.RawViewWalker;
        AutomationElement p = null;
        try { p = walker.GetParent(t); } catch { }
        int guard = 0;
        while (p != null && guard++ < 12) {
            if (p.Current.ControlType == ControlType.Button) return p;
            try { p = walker.GetParent(p); } catch { break; }
        }
        return null;
    }

    public static bool Focus(AutomationElement el) {
        if (el == null) return false;
        try { el.SetFocus(); return true; } catch { return false; }
    }

    public static string Dump(AutomationElement scope, int max) {
        if (scope == null) return "NULL SCOPE";
        var sb = new System.Text.StringBuilder();
        var all = scope.FindAll(TreeScope.Descendants, Condition.TrueCondition);
        int i = 0;
        foreach (AutomationElement e in all) {
            if (i++ >= max) break;
            var n = (e.Current.Name ?? "").Replace("\n", " ");
            if (n.Length > 70) n = n.Substring(0, 70);
            if (n.Length == 0) continue;
            sb.AppendLine(e.Current.ControlType.ProgrammaticName.Replace("ControlType.", "") + " | " + n);
        }
        return sb.ToString();
    }
}
"@
