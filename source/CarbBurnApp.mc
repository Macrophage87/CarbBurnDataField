using Toybox.Application;
using Toybox.WatchUi;

// Entry point. Data-field apps return a single DataField view.
class CarbBurnApp extends Application.AppBase {

    function initialize() {
        AppBase.initialize();
    }

    function onStart(state) {
    }

    function onStop(state) {
    }

    // Return the data field view.
    function getInitialView() {
        return [ new CarbBurnView() ];
    }

    // Called when the user edits settings in Garmin Connect Mobile.
    function onSettingsChanged() {
        WatchUi.requestUpdate();
    }
}
