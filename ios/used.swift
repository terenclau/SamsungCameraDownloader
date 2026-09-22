//
//  used.swift
//  CameraPocket
//
//  Created by Terence Lau on 9/21/26.
//


Camera Pocket is an iPhone app that transfers photos and MP4 videos directly from a Samsung DV300F
  camera to Apple Photos. It works over the camera’s own Wi-Fi network, so transfers don’t require an
  internet connection, router, or computer.

  To connect, enable MobileLink on the camera and join its Wi-Fi network from your iPhone. Camera
  Pocket then uses the camera’s ContentDirectory service to retrieve a list of available files and
  display them in a thumbnail grid. For the tested DV300F, the service address is
  http://192.168.11.1:52235/upnp/control/ContentDirectory1, with Use service URL enabled.

  You can tap individual items, select everything, or touch and hold an item before dragging across a
  range. Starting on a selected item lets you deselect a range. The updated selection behavior
  automatically scrolls when you hold your finger near the top or bottom of the grid, while ordinary
  swipes scroll normally.

  When you download your selection, the app retrieves the media files over HTTP and imports them into
  Apple Photos without recompression or metadata rewriting. This preserves the filenames and embedded
  metadata present in the files supplied by the camera, including photo EXIF data and video metadata.
  It cannot restore information the camera omits.

  Keep the app open during transfers. Progress and errors appear onscreen, and unsuccessful items
  remain selected for retry.

  done 8:20 PM


› Can you explain the technical aspect of how mobilelink works?


• I’ll explain the protocol used by the working DV300F connection and distinguish it from parts of
  Samsung’s original app we haven’t verified.

• Searching the web

• Searched the web for site:openconnectivity.org UPnP ContentDirectory Browse DIDL-Lite SSDP M-SEARCH

• On your DV300F, MobileLink exposes a local media server over Wi-Fi. Camera Pocket communicates with
  that server using UPnP commands and HTTP downloads. Here’s the technical sequence we’ve verified.

  1. Establish the network connection.
     The camera creates the DV300-d3:4f:12 Wi-Fi network. Your iPhone joins it and can reach the camera
     at 192.168.11.1. This provides a local network connection without internet access.

  2. Locate the camera’s service.
     Normally, a client uses SSDP discovery: it sends a UDP multicast M-SEARCH request to
     239.255.255.250:1900. Devices respond with a URL describing their available services. This is
     standard UPnP discovery. UPnP documentation
     (https://openconnectivity.org/foundation/faq/upnp-faq/)

     Discovery didn’t produce a response in your direct-network test, so our app bypasses it using the
     working address:

     http://192.168.11.1:52235/upnp/control/ContentDirectory1

  3. Request the file listing.
     The app sends an HTTP POST containing a SOAP XML Browse command to that address. It starts with
     root object 0, then browses folders such as 100PHOTO. The response contains DIDL-Lite XML,
     describing filenames, media types, sizes, and resource URLs. ContentDirectory specification
     (https://openconnectivity.org/wp-content/uploads/2015/11/UPnP-av-ContentDirectory-v4-Service-20101231.pdf)

  4. Download the selected resources.
     Each selected photo or video is fetched from its resource URL using HTTP. The app passes the
     downloaded file directly to Apple Photos, without re-encoding it, preserving embedded metadata
     supplied by the camera.

