// Copyright 2021-present 650 Industries. All rights reserved.

import CoreGraphics
import Photos
import UIKit
import ExpoModulesCore

public class ImageManipulatorModule: Module {
  typealias LoadImageCallback = (Result<UIImage, Error>) -> ()
  typealias SaveImageResult = (url: URL, data: Data)

  public func definition() -> ModuleDefinition {
    name("ExpoImageManipulator")

    function("manipulateAsync", manipulateImage)
      .runOnQueue(.main)
  }

  internal func manipulateImage(uri: String, actions: [ManipulateAction], options: ManipulateOptions, promise: Promise) {
    let url = urlFromUri(uri)

    loadImage(atUrl: url) { result in
      if case .failure(let error) = result {
        return promise.reject(error)
      }
      if case .success(let image) = result {
        do {
          let newImage = try manipulate(image: image, actions: actions)
          let saveResult = try self.saveImage(newImage, options: options)

          promise.resolve([
            "uri": saveResult.url.absoluteString,
            "width": newImage.cgImage?.width ?? 0,
            "height": newImage.cgImage?.height ?? 0,
            "base64": options.base64 ? saveResult.data.base64EncodedData() : nil
          ])
        } catch {
          promise.reject(error)
        }
      }
    }
  }

  internal func loadImage(atUrl url: URL, callback: @escaping LoadImageCallback) {
    if url.scheme == "data" {
      guard let data = try? Data(contentsOf: url), let image = UIImage(data: data) else {
        return callback(.failure(CorruptedImageDataError()))
      }
      return callback(.success(image))
    }
    if url.scheme == "assets-library" {
      // TODO: ALAsset URLs are deprecated as of iOS 11, we should migrate to `ph://` soon.
      return loadImageFromPhotoLibrary(url: url, callback: callback)
    }

    guard let imageLoader = self.appContext?.imageLoader else {
      return callback(.failure(ImageLoaderNotFoundError()))
    }
    guard let fileSystem = self.appContext?.fileSystem else {
      return callback(.failure(FileSystemNotFoundError()))
    }
    guard fileSystem.permissions(forURI: url).contains(.read) else {
      return callback(.failure(FileSystemReadPermissionError(path: url.absoluteString)))
    }

    imageLoader.loadImage(for: url) { error, image in
      guard let image = image, error == nil else {
        return callback(.failure(ImageLoadingFailedError(cause: error.debugDescription)))
      }
      callback(.success(image))
    }
  }

  internal func loadImageFromPhotoLibrary(url: URL, callback: @escaping LoadImageCallback) {
    guard let asset = PHAsset.fetchAssets(withALAssetURLs: [url], options: nil).firstObject else {
      return callback(.failure(ImageNotFoundError()))
    }
    let size = CGSize(width: asset.pixelWidth, height: asset.pixelHeight)
    let options = PHImageRequestOptions()

    options.resizeMode = .exact
    options.isNetworkAccessAllowed = true
    options.isSynchronous = true
    options.deliveryMode = .highQualityFormat

    PHImageManager.default().requestImage(for: asset, targetSize: size, contentMode: .aspectFit, options: options) { image, info in
      guard let image = image else {
        return callback(.failure(ImageNotFoundError()))
      }
      return callback(.success(image))
    }
  }

  internal func saveImage(_ image: UIImage, options: ManipulateOptions) throws -> SaveImageResult {
    guard let fileSystem = self.appContext?.fileSystem else {
      throw FileSystemNotFoundError()
    }
    let directory = URL(fileURLWithPath: fileSystem.cachesDirectory).appendingPathComponent("ImageManipulator")
    let filename = UUID().uuidString.appending(options.format.fileExtension)
    let fileUrl = directory.appendingPathComponent(filename)

    fileSystem.ensureDirExists(withPath: directory.absoluteString)

    guard let data = imageData(from: image, format: options.format, compression: options.compress) else {
      throw CorruptedImageDataError()
    }
    do {
      try data.write(to: fileUrl, options: .atomic)
    } catch let error {
      throw ImageWriteFailedError(cause: error.localizedDescription)
    }
    return (url: fileUrl, data: data)
  }
}

internal func urlFromUri(_ uri: String) -> URL {
  if let url = URL(string: uri), url.scheme != nil {
    return url
  }
  return URL(fileURLWithPath: uri, isDirectory: false)
}

internal struct ManipulateAction: Record {
  @Field
  var resize: ResizeOptions?

  @Field
  var rotate: Double?

  @Field
  var flip: FlipType?

  @Field
  var crop: CropRect?
}

internal struct ResizeOptions: Record {
  @Field
  var width: CGFloat?

  @Field
  var height: CGFloat?
}

internal struct CropRect: Record {
  @Field
  var originX: Double = 0.0

  @Field
  var originY: Double = 0.0

  @Field
  var width: Double = 0.0

  @Field
  var height: Double = 0.0

  func toRect() -> CGRect {
    return CGRect(x: originX, y: originY, width: width, height: height)
  }
}

internal struct ManipulateOptions: Record {
  @Field
  var base64: Bool = false

  @Field
  var compress: Double = 1.0

  @Field
  var format: ImageFormat = .jpeg
}

internal enum FlipType: String, EnumArgument {
  case vertical
  case horizontal
}

internal enum ImageFormat: String, EnumArgument {
  case jpeg
  case jpg
  case png

  var fileExtension: String {
    switch self {
    case .jpeg, .jpg:
      return ".jpg"
    case .png:
      return ".png"
    }
  }
}

func imageData(from image: UIImage, format: ImageFormat, compression: Double) -> Data? {
  switch format {
  case .jpeg, .jpg:
    return image.jpegData(compressionQuality: compression)
  case .png:
    return image.pngData()
  }
}
