import { requireNativeViewManager } from "expo-modules-core";
import * as React from "react";
const NativeView = requireNativeViewManager("ExpoMapboxNavigation");
export default React.forwardRef((props, ref) => {
    return <NativeView {...props} ref={ref}/>;
});
//# sourceMappingURL=ExpoMapboxNavigationView.js.map