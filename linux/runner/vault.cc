#include "vault.h"
#include <openssl/evp.h>
#include <cstring>
#include <limits>
#include <memory>
#include <string>
#include <vector>

namespace {
using Bytes = std::vector<uint8_t>;
struct Job {
  FlMethodCall* call;
  std::string method;
  Bytes key, salt, password, iv, name, data, output;
  bool ok = false;
};
bool process(Job& j) {
  if (j.method == "derive") {
    j.output.resize(32);
    return j.salt.size() == 16 &&
        PKCS5_PBKDF2_HMAC(reinterpret_cast<const char*>(j.password.data()), j.password.size(),
            j.salt.data(), j.salt.size(), 600000, EVP_sha256(), 32, j.output.data()) == 1;
  }
  const bool encrypt = j.method == "encrypt";
  if ((!encrypt && j.method != "decrypt") || j.key.size() != 32 || j.iv.size() != 12 ||
      (!encrypt && j.data.size() < 16) || j.data.size() > std::numeric_limits<int>::max() - 16) return false;
  const int size = static_cast<int>(j.data.size()) - (encrypt ? 0 : 16);
  std::unique_ptr<EVP_CIPHER_CTX, decltype(&EVP_CIPHER_CTX_free)> ctx(EVP_CIPHER_CTX_new(), EVP_CIPHER_CTX_free);
  if (!ctx || EVP_CipherInit_ex(ctx.get(), EVP_aes_256_gcm(), nullptr, j.key.data(), j.iv.data(), encrypt) != 1) return false;
  int count = 0, final = 0;
  j.output.resize(size + 16);
  if (EVP_CipherUpdate(ctx.get(), nullptr, &count, j.name.data(), j.name.size()) != 1 ||
      EVP_CipherUpdate(ctx.get(), j.output.data(), &count, j.data.data(), size) != 1) return false;
  if (!encrypt && EVP_CIPHER_CTX_ctrl(ctx.get(), EVP_CTRL_GCM_SET_TAG, 16, j.data.data() + size) != 1) return false;
  if (EVP_CipherFinal_ex(ctx.get(), j.output.data() + count, &final) != 1) return false;
  const int written = count + final;
  if (encrypt && EVP_CIPHER_CTX_ctrl(ctx.get(), EVP_CTRL_GCM_GET_TAG, 16, j.output.data() + written) != 1) return false;
  j.output.resize(written + (encrypt ? 16 : 0));
  return true;
}
Bytes field(FlValue* args, const char* name) {
  auto* v = fl_value_lookup_string(args, name);
  if (!v || fl_value_get_type(v) != FL_VALUE_TYPE_UINT8_LIST || !fl_value_get_length(v)) return {};
  auto* bytes = fl_value_get_uint8_list(v);
  return Bytes(bytes, bytes + fl_value_get_length(v));
}
void handler(FlMethodChannel*, FlMethodCall* call, gpointer) {
  auto* args = fl_method_call_get_args(call);
  auto* job = new Job{};
  job->call = FL_METHOD_CALL(g_object_ref(call));
  job->method = fl_method_call_get_name(call);
  job->password = field(args,"password"); job->salt=field(args,"salt");
  job->key=field(args,"key"); job->iv=field(args,"iv");
  job->name=field(args,"name"); job->data=field(args,"data");
  g_thread_unref(g_thread_new("eclipse-vault", [](gpointer data) -> gpointer {
    auto* j = static_cast<Job*>(data);
    j->ok = process(*j);
    g_idle_add([](gpointer data) -> gboolean {
      std::unique_ptr<Job> j(static_cast<Job*>(data));
      if (j->ok) {
        g_autoptr(FlValue) out = fl_value_new_uint8_list(j->output.data(), j->output.size());
        fl_method_call_respond_success(j->call, out, nullptr);
      } else {
        fl_method_call_respond_error(j->call,"vault","Could not unlock or process this file",nullptr,nullptr);
      }
      g_object_unref(j->call);
      return G_SOURCE_REMOVE;
    }, j);
    return nullptr;
  }, job));
}
}
void vault_start(FlView* view) {
  auto* messenger=fl_engine_get_binary_messenger(fl_view_get_engine(view));
  g_autoptr(FlStandardMethodCodec) codec=fl_standard_method_codec_new();
  g_autoptr(FlMethodChannel) channel=fl_method_channel_new(messenger,"eclipse/vault",FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(channel,handler,nullptr,nullptr);
}
