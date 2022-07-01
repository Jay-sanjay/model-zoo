# Spatial Transformer Network

#=
In this tutorial we'll build a spatial transformer network that will transform MNIST
digits for classification by a convolutional network

* [Spatial Transformer Networks](https://proceedings.neurips.cc/paper/2015/hash/33ceb07bf4eeb3da587e268d663aba1a-Abstract.html)

=#

using LinearAlgebra, Statistics
using Flux, CUDA, Zygote
using Flux: batch, onehotbatch, flatten, unsqueeze
using MLDatasets
using IterTools: partition
using Plots
using ProgressMeter
using ProgressMeter: Progress
## =====

args = Dict(
    :bsz => 64, # batch size
    :img_size => (28, 28), # mnist image size
    :n_epochs => 40, # no. epochs to train
)


## ==== GPU
dev = has_cuda() ? gpu : cpu

## ==== Data functions
"split your data into batches of size bsz"
get_batches(x; bsz=args[:bsz]) = batch.(partition(x, bsz))

function get_mnist_data()
    train_digits, train_labels = MNIST(split=:train)[:]
    test_digits, test_labels = MNIST(split=:test)[:]
    xs_train, xs_test = map(get_batches, (eachslice(train_digits, dims=3), eachslice(test_digits, dims=3)))

    ys_train = map(x -> Float32.(onehotbatch(x, 0:9)), get_batches(train_labels))
    ys_test = map(x -> Float32.(onehotbatch(x, 0:9)), get_batches(test_labels))

    return xs_train, xs_test, ys_train, ys_test
end

## ==== interpolation functions

"generate sampling grid 3 x (width x height) x (batch size)"
function get_sampling_grid(width, height; args=args)
    x = collect(LinRange(-1, 1, width))
    y = collect(LinRange(-1, 1, height))
    x_t_flat = reshape(repeat(x, height), 1, height * width)
    y_t_flat = reshape(repeat(transpose(y), width), 1, height * width)
    all_ones = ones(eltype(x_t_flat), 1, size(x_t_flat)[2])
    sampling_grid = vcat(x_t_flat, y_t_flat, all_ones)
    sampling_grid = reshape(
        transpose(repeat(transpose(sampling_grid), args[:bsz])),
        3,
        size(x_t_flat)[2],
        args[:bsz],
    )
    return collect(Float32.(sampling_grid))
end

"transform sampling_grid using parameters thetas"
function affine_grid_generator(sampling_grid, thetas; args=args, sz=args[:img_size])
    bsz = size(thetas)[end]
    # we're gonna be multiplying the offsets thetas[5,6] by the scale thetas[1,4]
    theta = Zygote.Buffer(thetas)
    theta[1:4, :] = thetas[1:4, :]
    theta[[5, 6], :] = thetas[[1, 4], :] .* thetas[[5, 6], :]
    th_ = reshape(copy(theta), 2, 3, bsz)
    transformed_grid = batched_mul(th_, sampling_grid)
    # reshape to 2 x height x width x (batch size)
    return reshape(transformed_grid, 2, sz..., bsz)
end

"sample image x at points determined by transforming sampling_grid by thetas"
function sample_patch(x, thetas, sampling_grid; sz=args[:img_size])
    ximg = reshape(x, sz..., 1, size(x)[end])
    tr_grid = affine_grid_generator(sampling_grid, thetas; sz=sz)
    grid_sample(ximg, tr_grid; padding_mode=:zeros)
end

## ==== model functions
"transform image with localization net"
function transform_image(x)
    thetas = localization_net(x)
    return sample_patch(x, thetas, sampling_grid)
end

function model_loss(x, y)
    # transform x with localization net
    xnew = transform_image(x)
    ŷ = classifier(xnew)
    Flux.crossentropy(ŷ, y)
end

"train_data should be a tuple of (images, labels)"
function train_model(opt, ps, train_data; epoch=1)
    progress_tracker = Progress(length(train_data), 1, "Training epoch $epoch :)")
    losses = zeros(length(train_data))
    @inbounds for (i, (x, y)) in enumerate(train_data)
        loss, back = pullback(ps) do
            model_loss(x, y)
        end
        grad = back(1.0f0)
        Flux.update!(opt, ps, grad)
        losses[i] = loss
        ProgressMeter.next!(progress_tracker; showvalues=[(:loss, loss)])
    end
    return losses
end

accuracy(ŷ, y) = mean(Flux.onecold(ŷ) .== Flux.onecold(y))

"test_data should be a tuple of (images, labels)"
function test_model(test_data)
    L, acc = 0.0f0, 0
    @inbounds for (x, y) in test_data
        L += model_loss(x, y)

        xnew = transform_image(x)
        ŷ = classifier(xnew)
        acc += accuracy(ŷ, y)
    end
    return L / length(test_data), round(acc * 100 / length(test_data), digits=3)
end

## === plotting functions
"plot x (width x height x (batch size)) as a grid"
function plot_batch(x)
    # drop 3rd singleton dim if applicable
    x = length(size(x)) > 3 ? dropdims(x, dims=3) : x
    bsz = size(x)[end]
    wh = trunc(Int, sqrt(bsz))
    x_vec = collect(eachslice(cpu(x), dims=3))
    a = collect(partition(x_vec, wh))
    b = map(x -> vcat(x...), a)
    heatmap(hcat(b...)[:, end:-1:1]', c=:grays, axis=nothing, colorbar=false)
end

"""
visualize batch x (ncols by ncols) after
transformation by localization net
"""
function plot_stn(x; ncols=6)
    n_samples = ncols^2
    x̄ = transform_image(x) |> cpu
    p1 = plot_batch(cpu(x)[:, :, 1:n_samples])
    title!("Original")
    p2 = plot_batch(x̄[:, :, 1, 1:n_samples])
    title!("Transformed")
    plot(p1, p2)
end

## ==== Models

"Generates alignment parameters from image"
localization_net = Chain(
    x -> reshape(x, size(x)[1:2]..., 1, size(x)[end]), # reshape for Conv layer
    Conv((5, 5), 1 => 20, stride=(1, 1), pad=(0, 0)),
    MaxPool((2, 2)), Conv((5, 5), 20 => 20, stride=(1, 1), pad=(0, 0)),
    flatten,
    Dense(1280, 50, relu),
    Dense(50, 6)) |> dev

"Classifies images transformed by localization_net"
classifier = Chain(
    Conv((3, 3), 1 => 32, relu), MaxPool((2, 2)),
    Conv((3, 3), 32 => 32, relu), MaxPool((2, 2)),
    flatten,
    Dense(800, 256, relu),
    Dense(256, 10),
    softmax
) |> dev

ps = Flux.params(localization_net, classifier)
## ====
# create sampling grid
const sampling_grid = get_sampling_grid(args[:img_size]...) |> dev
## ====

# get data
xs_train, xs_test, ys_train, ys_test = get_mnist_data() |> dev

opt = ADAM(1e-4)

for epoch in 1:args[:n_epochs]
    ls = train_model(opt, ps, zip(xs_train, ys_train); epoch=epoch)

    # visualize transformations for a random test set batch
    p = plot_stn(rand(xs_test))
    display(p)

    Ltest, test_acc = test_model(zip(xs_test, ys_test))
    @info "Test loss: $Ltest, test accuracy: $test_acc%"

end

