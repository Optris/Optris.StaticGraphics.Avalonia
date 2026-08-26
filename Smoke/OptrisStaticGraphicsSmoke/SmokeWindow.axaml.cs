using Avalonia.Controls;

namespace Optris.StaticGraphics.Smoke;

public sealed partial class SmokeWindow : Window
{
    public SmokeWindow()
    {
        InitializeComponent();
    }

    internal void Attach(SceneHost host) => Host.Children.Add(host.Root);
}
