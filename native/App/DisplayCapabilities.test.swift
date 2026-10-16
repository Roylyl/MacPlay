import Foundation

@main struct DisplayCapabilitiesTests {
    static func main() {
        let fixture = #"{"SPDisplaysDataType":[{"spdisplays_ndrvs":[{"_spdisplays_displayID":"1","spdisplays_pixelresolution":"spdisplays_3456x2234Retina"},{"_spdisplays_displayID":"0xA","spdisplays_pixelresolution":"1920 x 1080"},{"_spdisplays_displayID":"2","spdisplays_pixelresolution":"unknown"}]}]}"#
        let pixels=DisplayCapabilities.parse(Data(fixture.utf8))!
        precondition(pixels[1] == DisplayPixels(width:3456,height:2234))
        precondition(pixels[10] == DisplayPixels(width:1920,height:1080))
        precondition(pixels[2] == nil)
        precondition(DisplayCapabilities.parse(Data("invalid".utf8)) == nil)
        for loading in [true,false] {
            precondition(!DisplayCapabilities.permitsExactPixels(verified:false,widthMm:300,heightMm:200,loading:loading))
        }
        precondition(!DisplayCapabilities.permitsExactPixels(verified:true,widthMm:0,heightMm:200,loading:false))
        precondition(!DisplayCapabilities.permitsExactPixels(verified:true,widthMm:300,heightMm:200,loading:true))
        precondition(DisplayCapabilities.permitsExactPixels(verified:true,widthMm:300,heightMm:200,loading:false))
        let fitted=DisplayCapabilities.fittedSize(width:3840,height:2160,visibleWidth:800,visibleHeight:600)
        precondition(fitted.0==640 && fitted.1==360)
        let result=BoundedSystemQuery.run(executable:"/bin/echo",arguments:["display-query"])
        precondition(result.error==nil && String(data:result.data,encoding:.utf8)=="display-query\n")
        let start=Date()
        let timeout=BoundedSystemQuery.run(executable:"/bin/sleep",arguments:["5"],timeout:0.05)
        precondition(timeout.error=="TIMEOUT" && Date().timeIntervalSince(start)<2)
        print("Display capability parsing, strict gates, ordinary fit and query timeout passed")
    }
}
