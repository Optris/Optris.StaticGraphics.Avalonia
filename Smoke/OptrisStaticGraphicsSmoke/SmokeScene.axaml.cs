using Avalonia.Controls;

namespace Optris.StaticGraphics.Smoke;

public sealed partial class SmokeScene : Grid
{
    internal SmokeScene(SelfTest selfTest)
    {
        InitializeComponent();

        // The self-test modes are how the assertions are shown to have teeth: a scene that draws
        // nothing, or one flat colour, is what a null GPU context looks like from the outside, and
        // the run that produces it has to fail.
        switch (selfTest)
        {
            case SelfTest.Blank:
                Children.Clear();
                Background = null;
                break;
            case SelfTest.Uniform:
                Children.Clear();
                break;
        }
    }

    public SmokeScene()
        : this(SelfTest.None)
    {
    }
}
