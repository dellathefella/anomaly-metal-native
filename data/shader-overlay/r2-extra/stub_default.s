-- stub_default.s — l_shader fallback (Metal r2 tree port addition; same
-- content as the GL overlay's gl/stub_default.s). Pairs with the
-- stub_default.vs/.ps pass-through pair.
function normal		(shader, t_base, t_second, t_detail)
	shader:begin	("stub_default","stub_default")
	shader:sampler	("s_base")	: texture(t_base)	: clamp() : f_linear ()
end
