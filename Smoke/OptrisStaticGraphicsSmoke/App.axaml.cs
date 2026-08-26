using Avalonia;
using Avalonia.Markup.Xaml;

namespace Optris.StaticGraphics.Smoke;

public sealed partial class App : Application
{
    public override void Initialize()
    {
        AvaloniaXamlLoader.Load(this);
    }

    // The window is created by SmokeRunner once the platform is up, so the run can report a startup
    // failure instead of dying inside framework initialisation.
    public override void OnFrameworkInitializationCompleted()
    {
        base.OnFrameworkInitializationCompleted();
    }
}
