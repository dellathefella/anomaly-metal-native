-- p4 t4 alias: Anomaly l_shader 'fluid3d_stub' -> OpenXRay GL implementation
function normal		(shader, t_base, t_second, t_detail)
	shader:begin	("stub_default","stub_default")
	shader:sampler	("s_base")	: texture(t_base)	: clamp() : f_linear ()
end
