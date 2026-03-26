#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <memory>
#include <set>
#include <sstream>
#include <string>
#include <vector>

#include <opencv2/imgcodecs.hpp>
#include <opencv2/imgproc.hpp>

#include <rtabmap/core/DBDriver.h>
#include <rtabmap/core/Parameters.h>
#include <rtabmap/core/SensorData.h>

namespace fs = std::filesystem;

namespace {

struct Options {
  fs::path db_path;
  fs::path output_dir;
  int frame_stride = 1;
  int point_stride = 24;
  float max_depth_m = 4.5f;
  bool overwrite = false;
};

struct FrameRecord {
  std::string file_path;
  double fl_x = 0.0;
  double fl_y = 0.0;
  double cx = 0.0;
  double cy = 0.0;
  int width = 0;
  int height = 0;
  double k1 = 0.0;
  double k2 = 0.0;
  double k3 = 0.0;
  double k4 = 0.0;
  double p1 = 0.0;
  double p2 = 0.0;
  float transform[4][4] = {{0.0f}};
};

struct SeedPoint {
  float x = 0.0f;
  float y = 0.0f;
  float z = 0.0f;
  unsigned char r = 0;
  unsigned char g = 0;
  unsigned char b = 0;
};

[[noreturn]] void fail(const std::string &message) {
  std::cerr << "ERROR: " << message << std::endl;
  std::exit(1);
}

bool has_arg(const std::string &value, const char *short_name, const char *long_name) {
  return value == short_name || value == long_name;
}

Options parse_args(int argc, char **argv) {
  Options opts;

  for (int i = 1; i < argc; ++i) {
    const std::string arg(argv[i]);
    auto require_value = [&](const std::string &flag) -> std::string {
      if (i + 1 >= argc) {
        fail("missing value for " + flag);
      }
      ++i;
      return argv[i];
    };

    if (has_arg(arg, "-d", "--db")) {
      opts.db_path = require_value(arg);
    } else if (has_arg(arg, "-o", "--output-dir")) {
      opts.output_dir = require_value(arg);
    } else if (arg == "--frame-stride") {
      opts.frame_stride = std::stoi(require_value(arg));
    } else if (arg == "--point-stride") {
      opts.point_stride = std::stoi(require_value(arg));
    } else if (arg == "--max-depth-m") {
      opts.max_depth_m = std::stof(require_value(arg));
    } else if (arg == "--overwrite") {
      opts.overwrite = true;
    } else if (has_arg(arg, "-h", "--help")) {
      std::cout
          << "Usage: rtabmap_db_to_nerfstudio --db <rtabmap.db> --output-dir <dataset-dir> [options]\n"
          << "\n"
          << "Options:\n"
          << "  --frame-stride <N>   Keep every Nth frame (default: 1)\n"
          << "  --point-stride <N>   Depth sampling stride for sparse seed cloud (default: 24)\n"
          << "  --max-depth-m <M>    Ignore depth beyond M meters when building the seed cloud (default: 4.5)\n"
          << "  --overwrite          Replace an existing dataset directory\n";
      std::exit(0);
    } else {
      fail("unknown argument: " + arg);
    }
  }

  if (opts.db_path.empty()) {
    fail("--db is required");
  }
  if (opts.output_dir.empty()) {
    fail("--output-dir is required");
  }
  if (opts.frame_stride <= 0) {
    fail("--frame-stride must be > 0");
  }
  if (opts.point_stride <= 0) {
    fail("--point-stride must be > 0");
  }
  if (opts.max_depth_m <= 0.0f) {
    fail("--max-depth-m must be > 0");
  }

  return opts;
}

fs::path image_path_for_index(const fs::path &images_dir, std::size_t index) {
  std::ostringstream name;
  name << "frame_" << std::setw(6) << std::setfill('0') << index << ".jpg";
  return images_dir / name.str();
}

rtabmap::Transform camera_pose_opencv(const rtabmap::Transform &robot_pose, const rtabmap::CameraModel &model) {
  return robot_pose * model.localTransform();
}

rtabmap::Transform opencv_pose_to_opengl(rtabmap::Transform pose) {
  for (int row = 0; row < 3; ++row) {
    pose(row, 1) *= -1.0f;
    pose(row, 2) *= -1.0f;
  }
  return pose;
}

void fill_transform_matrix(const rtabmap::Transform &pose, float out[4][4]) {
  out[0][0] = pose.r11();
  out[0][1] = pose.r12();
  out[0][2] = pose.r13();
  out[0][3] = pose.o14();
  out[1][0] = pose.r21();
  out[1][1] = pose.r22();
  out[1][2] = pose.r23();
  out[1][3] = pose.o24();
  out[2][0] = pose.r31();
  out[2][1] = pose.r32();
  out[2][2] = pose.r33();
  out[2][3] = pose.o34();
  out[3][0] = 0.0f;
  out[3][1] = 0.0f;
  out[3][2] = 0.0f;
  out[3][3] = 1.0f;
}

void append_seed_points(
    const cv::Mat &image_bgr,
    const cv::Mat &depth_raw,
    const rtabmap::CameraModel &model,
    const rtabmap::Transform &camera_pose,
    int point_stride,
    float max_depth_m,
    std::vector<SeedPoint> &out_points) {
  if (image_bgr.empty() || depth_raw.empty()) {
    return;
  }

  const int rows = std::min(image_bgr.rows, depth_raw.rows);
  const int cols = std::min(image_bgr.cols, depth_raw.cols);
  if (rows <= 0 || cols <= 0) {
    return;
  }

  for (int v = 0; v < rows; v += point_stride) {
    for (int u = 0; u < cols; u += point_stride) {
      float depth_m = 0.0f;
      switch (depth_raw.type()) {
        case CV_16UC1:
          depth_m = static_cast<float>(depth_raw.at<std::uint16_t>(v, u)) * 0.001f;
          break;
        case CV_32FC1:
          depth_m = depth_raw.at<float>(v, u);
          break;
        default:
          continue;
      }

      if (!std::isfinite(depth_m) || depth_m <= 0.0f || depth_m > max_depth_m) {
        continue;
      }

      float x = 0.0f;
      float y = 0.0f;
      float z = 0.0f;
      model.project(static_cast<float>(u), static_cast<float>(v), depth_m, x, y, z);

      SeedPoint point;
      point.x = camera_pose.r11() * x + camera_pose.r12() * y + camera_pose.r13() * z + camera_pose.o14();
      point.y = camera_pose.r21() * x + camera_pose.r22() * y + camera_pose.r23() * z + camera_pose.o24();
      point.z = camera_pose.r31() * x + camera_pose.r32() * y + camera_pose.r33() * z + camera_pose.o34();

      const cv::Vec3b color = image_bgr.at<cv::Vec3b>(v, u);
      point.r = color[2];
      point.g = color[1];
      point.b = color[0];
      out_points.push_back(point);
    }
  }
}

void write_ascii_ply(const fs::path &path, const std::vector<SeedPoint> &points) {
  if (points.empty()) {
    return;
  }

  std::ofstream out(path);
  if (!out) {
    fail("failed to open output PLY: " + path.string());
  }

  out << "ply\n";
  out << "format ascii 1.0\n";
  out << "element vertex " << points.size() << "\n";
  out << "property float x\n";
  out << "property float y\n";
  out << "property float z\n";
  out << "property uchar red\n";
  out << "property uchar green\n";
  out << "property uchar blue\n";
  out << "end_header\n";
  out << std::fixed << std::setprecision(6);

  for (const SeedPoint &point : points) {
    out << point.x << ' ' << point.y << ' ' << point.z << ' ' << static_cast<int>(point.r) << ' '
        << static_cast<int>(point.g) << ' ' << static_cast<int>(point.b) << '\n';
  }
}

void write_transforms_json(const fs::path &path, const std::vector<FrameRecord> &frames, bool has_ply) {
  std::ofstream out(path);
  if (!out) {
    fail("failed to open transforms.json for writing: " + path.string());
  }

  out << "{\n";
  out << "  \"camera_model\": \"OPENCV\",\n";
  out << "  \"orientation_override\": \"none\",\n";
  if (has_ply) {
    out << "  \"ply_file_path\": \"sparse_pc.ply\",\n";
  }
  out << "  \"frames\": [\n";
  out << std::fixed << std::setprecision(8);

  for (std::size_t i = 0; i < frames.size(); ++i) {
    const FrameRecord &frame = frames[i];
    out << "    {\n";
    out << "      \"file_path\": \"" << frame.file_path << "\",\n";
    out << "      \"fl_x\": " << frame.fl_x << ",\n";
    out << "      \"fl_y\": " << frame.fl_y << ",\n";
    out << "      \"cx\": " << frame.cx << ",\n";
    out << "      \"cy\": " << frame.cy << ",\n";
    out << "      \"w\": " << frame.width << ",\n";
    out << "      \"h\": " << frame.height << ",\n";
    out << "      \"k1\": " << frame.k1 << ",\n";
    out << "      \"k2\": " << frame.k2 << ",\n";
    out << "      \"k3\": " << frame.k3 << ",\n";
    out << "      \"k4\": " << frame.k4 << ",\n";
    out << "      \"p1\": " << frame.p1 << ",\n";
    out << "      \"p2\": " << frame.p2 << ",\n";
    out << "      \"transform_matrix\": [\n";
    for (int row = 0; row < 4; ++row) {
      out << "        [";
      for (int col = 0; col < 4; ++col) {
        out << frame.transform[row][col];
        if (col < 3) {
          out << ", ";
        }
      }
      out << "]";
      if (row < 3) {
        out << ",";
      }
      out << "\n";
    }
    out << "      ]\n";
    out << "    }";
    if (i + 1 < frames.size()) {
      out << ",";
    }
    out << "\n";
  }

  out << "  ]\n";
  out << "}\n";
}

}  // namespace

int main(int argc, char **argv) {
  const Options options = parse_args(argc, argv);

  if (!fs::exists(options.db_path)) {
    fail("database not found: " + options.db_path.string());
  }

  if (fs::exists(options.output_dir)) {
    if (!options.overwrite) {
      fail("output directory already exists; pass --overwrite to replace it: " + options.output_dir.string());
    }
    fs::remove_all(options.output_dir);
  }

  const fs::path images_dir = options.output_dir / "images";
  fs::create_directories(images_dir);

  std::unique_ptr<rtabmap::DBDriver> driver(rtabmap::DBDriver::create(rtabmap::ParametersMap()));
  if (!driver) {
    fail("failed to create RTAB-Map DB driver");
  }
  if (!driver->openConnection(options.db_path.string(), false)) {
    fail("failed to open RTAB-Map database: " + options.db_path.string());
  }

  std::set<int> node_ids;
  driver->getAllNodeIds(node_ids, false, false, false);
  if (node_ids.empty()) {
    fail("database has no nodes: " + options.db_path.string());
  }

  std::vector<FrameRecord> frames;
  std::vector<SeedPoint> seed_points;
  frames.reserve(node_ids.size());

  std::size_t selected_index = 0;
  std::size_t total_seen = 0;

  for (int node_id : node_ids) {
    ++total_seen;
    if (((total_seen - 1) % static_cast<std::size_t>(options.frame_stride)) != 0) {
      continue;
    }

    rtabmap::Transform robot_pose;
    int map_id = 0;
    int weight = 0;
    std::string label;
    double stamp = 0.0;
    rtabmap::Transform ground_truth_pose;
    std::vector<float> velocity;
    rtabmap::GPS gps;
    rtabmap::EnvSensors sensors;
    driver->getNodeInfo(node_id, robot_pose, map_id, weight, label, stamp, ground_truth_pose, velocity, gps, sensors);

    if (robot_pose.isNull()) {
      continue;
    }

    rtabmap::SensorData data;
    driver->getNodeData(node_id, data, true, false, false, false);

    cv::Mat image_raw;
    cv::Mat depth_raw;
    data.uncompressDataConst(&image_raw, &depth_raw);
    if (image_raw.empty()) {
      continue;
    }

    const std::vector<rtabmap::CameraModel> &camera_models = data.cameraModels();
    if (camera_models.empty()) {
      continue;
    }
    const rtabmap::CameraModel &model = camera_models.front();
    if (!model.isValidForProjection()) {
      continue;
    }

    const rtabmap::Transform camera_pose_cv = camera_pose_opencv(robot_pose, model);
    const rtabmap::Transform camera_pose_gl = opencv_pose_to_opengl(camera_pose_cv);

    const fs::path image_path = image_path_for_index(images_dir, selected_index + 1);
    if (!cv::imwrite(image_path.string(), image_raw)) {
      fail("failed to write image: " + image_path.string());
    }

    FrameRecord frame;
    frame.file_path = fs::relative(image_path, options.output_dir).generic_string();
    frame.fl_x = model.fx();
    frame.fl_y = model.fy();
    frame.cx = model.cx();
    frame.cy = model.cy();
    frame.width = model.imageWidth() > 0 ? model.imageWidth() : image_raw.cols;
    frame.height = model.imageHeight() > 0 ? model.imageHeight() : image_raw.rows;

    const cv::Mat distortion = model.D();
    if (!distortion.empty()) {
      const int coeffs = distortion.cols > 0 ? distortion.cols : distortion.rows;
      auto read_coeff = [&](int idx) -> double {
        if (idx >= coeffs) {
          return 0.0;
        }
        return distortion.cols > 0 ? distortion.at<double>(0, idx) : distortion.at<double>(idx, 0);
      };
      frame.k1 = read_coeff(0);
      frame.k2 = read_coeff(1);
      frame.p1 = read_coeff(2);
      frame.p2 = read_coeff(3);
      frame.k3 = read_coeff(4);
      frame.k4 = read_coeff(5);
    }

    fill_transform_matrix(camera_pose_gl, frame.transform);
    frames.push_back(frame);

    append_seed_points(image_raw, depth_raw, model, camera_pose_cv, options.point_stride, options.max_depth_m, seed_points);
    ++selected_index;
  }

  driver->closeConnection();

  if (frames.size() < 2) {
    fail("fewer than 2 usable frames were extracted from the database");
  }

  if (!seed_points.empty()) {
    write_ascii_ply(options.output_dir / "sparse_pc.ply", seed_points);
  }
  write_transforms_json(options.output_dir / "transforms.json", frames, !seed_points.empty());
  {
    std::ofstream marker(options.output_dir / ".rtabmap_nerfstudio_export");
    marker << "source=rtabmap_db\n";
  }

  std::cout << "Extracted " << frames.size() << " frames to " << options.output_dir << std::endl;
  if (!seed_points.empty()) {
    std::cout << "Wrote sparse seed cloud with " << seed_points.size() << " points." << std::endl;
  } else {
    std::cout << "No depth-derived seed cloud was generated." << std::endl;
  }
  return 0;
}
