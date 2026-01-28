#scope_module

Texture :: struct {
    desc: Gpu_Texture_Desc;
    mtl_texture: *MTLTexture;
}

live_textures: Pool(Gpu_Texture, Texture, max = MAX_IMAGES);

// TODO
